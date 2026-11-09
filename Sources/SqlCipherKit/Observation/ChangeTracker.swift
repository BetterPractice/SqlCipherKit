import CSqlCipher

// MARK: - WriteSet

/// The tables a compiled statement can modify, as reported by SQLite's
/// authorizer while the statement was prepared.
///
/// Names are lowercased: SQLite table names are case-insensitive.
struct WriteSet: Sendable, Equatable {
    /// Targets of INSERT, UPDATE and DELETE, including those performed by
    /// triggers and foreign-key actions compiled into the statement.
    var rowTables: Set<String> = []
    /// Tables created, dropped or altered.  DDL changes no rows, so these are
    /// reported whether or not the row-change counter moved.
    var schemaTables: Set<String> = []

    static let empty = WriteSet()
}

// MARK: - ChangeTracker

/// Detects which tables each transaction changed and reports them once the
/// transaction ends.
///
/// Detection has two halves:
///
/// 1. **Compile time.**  While a statement is prepared through
///    ``compile(_:)``, the connection's authorizer callback records the
///    tables the statement can write into a ``WriteSet``.  Cached statements
///    keep their write set, so the cost is paid once per SQL string.
/// 2. **Run time.**  When a statement finishes, ``statementFinished(_:)``
///    adds its write set to the pending set if `sqlite3_total_changes64`
///    moved (DDL is added unconditionally).  When the connection is back in
///    autocommit mode the transaction is over, and the pending tables are
///    handed to ``onTransactionEnd``.
///
/// Committed and rolled-back transactions are reported alike.  A rollback
/// produces a harmless extra notification: observers re-fetch, find the
/// same rows, and publish nothing.  Reporting rollbacks also covers an
/// observer that fetched uncommitted rows from an open transaction on this
/// connection, which must re-fetch once those rows are rolled back.
///
/// Not `Sendable`: like ``StatementCache``, it is only touched on the owning
/// ``Database`` actor's executor.
final class ChangeTracker {

    private let db: OpaquePointer
    /// Non-nil only while ``compile(_:)`` is preparing a statement.
    private var compiling: WriteSet?
    /// Tables changed by the transaction in progress.
    private var pending: Set<String> = []
    /// `sqlite3_total_changes64` after the previous statement finished.
    private var lastTotalChanges: Int64

    /// Called with the changed tables each time a transaction ends.
    var onTransactionEnd: ((Set<String>) -> Void)?

    init(db: OpaquePointer) {
        self.db = db
        self.lastTotalChanges = sqlite3_total_changes64(db)
        sqlite3_set_authorizer(
            db,
            { context, action, arg1, arg2, _, _ in
                if let context {
                    Unmanaged<ChangeTracker>.fromOpaque(context)
                        .takeUnretainedValue()
                        .authorize(action, arg1, arg2)
                }
                return SQLITE_OK
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Removes the authorizer.  The owning `Database` calls this before
    /// closing the handle, so SQLite never calls back into a freed tracker.
    func detach() {
        sqlite3_set_authorizer(db, nil, nil)
    }

    // MARK: Compile time

    /// Prepares a statement with `prepare` and returns it with the tables it
    /// can write.
    func compile(_ prepare: () throws -> OpaquePointer) rethrows -> (OpaquePointer, WriteSet) {
        compiling = WriteSet()
        defer { compiling = nil }
        let statement = try prepare()
        return (statement, compiling ?? .empty)
    }

    /// Authorizer callback body.  Statements prepared outside ``compile(_:)``
    /// (opening checks, SQLite's automatic re-prepare after a schema change)
    /// are ignored; a re-prepared statement keeps its original write set.
    private func authorize(
        _ action: Int32,
        _ arg1: UnsafePointer<CChar>?,
        _ arg2: UnsafePointer<CChar>?
    ) {
        guard compiling != nil else { return }
        switch action {
        case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE:
            if let name = Self.userTable(arg1) { compiling!.rowTables.insert(name) }
        case SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_TABLE,
             SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_TABLE:
            if let name = Self.userTable(arg1) { compiling!.schemaTables.insert(name) }
        case SQLITE_ALTER_TABLE:
            // arg1 is the schema name, arg2 the table.
            if let name = Self.userTable(arg2) { compiling!.schemaTables.insert(name) }
        default:
            break
        }
    }

    /// Lowercased table name, or `nil` for SQLite's internal tables, which
    /// DDL statements write to as a side effect.
    private static func userTable(_ cName: UnsafePointer<CChar>?) -> String? {
        guard let cName else { return nil }
        let name = String(cString: cName).lowercased()
        return name.hasPrefix("sqlite_") ? nil : name
    }

    // MARK: Run time

    /// Records a finished statement.  Call after the statement has been reset
    /// or finalized, so the autocommit state reflects its completion.
    func statementFinished(_ writes: WriteSet) {
        let total = sqlite3_total_changes64(db)
        if total != lastTotalChanges {
            pending.formUnion(writes.rowTables)
            lastTotalChanges = total
        }
        pending.formUnion(writes.schemaTables)

        guard sqlite3_get_autocommit(db) != 0, !pending.isEmpty else { return }
        let tables = pending
        pending = []
        onTransactionEnd?(tables)
    }
}
