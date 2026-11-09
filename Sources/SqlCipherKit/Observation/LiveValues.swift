// MARK: - Database: live values

extension Database {

    /// An asynchronous sequence of `request`'s result: the current value
    /// first, then a new value each time a committed change alters it.
    ///
    /// ```swift
    /// for try await products in db.values(of: .fetch(Product.self, orderBy: col("name").ascending)) {
    ///     try await socket.send(JSONEncoder().encode(products))
    /// }
    /// ```
    ///
    /// Behaviour:
    ///
    /// - **Pull-based.**  Commits only mark the observation dirty; the query
    ///   runs when the consumer asks for the next value.  A slow consumer
    ///   receives the current state, never a backlog, and commits made while
    ///   it is busy cost one fetch in total.
    /// - **Duplicate-free.**  A commit that touches the table without changing
    ///   this request's rows produces no value.  Rows are compared before
    ///   they are decoded.
    /// - **Fetched on the database actor.**  Only the decoded result crosses
    ///   to the consumer, which receives it on its own executor.
    /// - **Reported when a transaction ends.**  Writes inside a transaction
    ///   produce one value, after the transaction commits or rolls back.
    /// - **This connection only.**  Only writes made through this `Database`
    ///   are seen: changes by other processes or other connections to the
    ///   same file are not.
    ///
    /// ### Transactions left open across calls
    ///
    /// ``transaction(_:)``, ``Connection/savepoint(_:)``, batch saves, and
    /// migrations run as one synchronous call on the actor, so an observer
    /// can never fetch while one of them is in progress.  Prefer them.
    ///
    /// A transaction managed by hand across separate calls is different:
    ///
    /// ```swift
    /// try await db.execute("BEGIN")
    /// try await db.save(product)   // an observer may fetch here
    /// try await db.execute("COMMIT")
    /// ```
    ///
    /// An observer that already has a pending change may fetch between those
    /// calls and deliver rows that are not yet committed.  It re-fetches when
    /// the transaction ends, so a rollback is corrected by the next value.
    /// This is deliberate: a transaction accidentally left open would
    /// otherwise stall every observer indefinitely.
    ///
    /// The sequence ends (returns `nil`) when its task is cancelled, and
    /// throws if a fetch fails.
    public nonisolated func values<Result>(of request: LiveRequest<Result>) -> LiveValues<Result> {
        LiveValues(database: self, request: request)
    }

    // MARK: Internal (called by LiveValues.Iterator)

    /// Registers an observer and fetches its first value in one actor turn, so
    /// no commit can fall between the two.
    func _startObserving<Result>(
        _ request: LiveRequest<Result>
    ) throws -> (ObserverRegistry.ID, Result) {
        let id = observers.register(tables: request.tables)
        do {
            let rows = try withConnection { try $0._query(request.query) }
            _ = observers.replaceRows(id, with: rows.map(\.rawValues))
            return (id, try request.decode(rows, complexColumnStrategy))
        } catch {
            observers.unregister(id)
            throw error
        }
    }

    /// Waits for a relevant change and returns the new value, skipping
    /// changes that leave the rows unchanged.  Returns `nil` once the
    /// observer is removed.
    func _nextValue<Result>(
        _ id: ObserverRegistry.ID,
        _ request: LiveRequest<Result>
    ) async throws -> Result? {
        while await _waitForChange(id) {
            let rows = try withConnection { try $0._query(request.query) }
            if observers.replaceRows(id, with: rows.map(\.rawValues)) {
                return try request.decode(rows, complexColumnStrategy)
            }
        }
        return nil
    }

    func _stopObserving(_ id: ObserverRegistry.ID) {
        observers.unregister(id)
    }

    /// The number of registered observers.  Exposed for tests.
    var _observerCount: Int { observers.count }

    /// `true` when a change is pending or arrives; `false` when the observer
    /// has been removed.
    private func _waitForChange(_ id: ObserverRegistry.ID) async -> Bool {
        switch observers.consume(id) {
        case .changed: return true
        case .removed: return false
        case .unchanged:
            return await withCheckedContinuation { observers.setWaiter(id, $0) }
        }
    }
}

// MARK: - LiveValues

/// The asynchronous sequence returned by ``Database/values(of:)``.
public struct LiveValues<Result: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Result

    let database: Database
    let request: LiveRequest<Result>

    public func makeAsyncIterator() -> Iterator {
        Iterator(database: database, request: request)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let database: Database
        private let request: LiveRequest<Result>
        private var registration: Registration?
        private var finished = false

        init(database: Database, request: LiveRequest<Result>) {
            self.database = database
            self.request = request
        }

        public mutating func next() async throws -> Result? {
            guard !finished else { return nil }
            do {
                guard let registration else {
                    let (id, value) = try await database._startObserving(request)
                    registration = Registration(database: database, id: id)
                    return value
                }
                let database = self.database
                let request = self.request
                let id = registration.id
                let value = try await withTaskCancellationHandler {
                    try await database._nextValue(id, request)
                } onCancel: {
                    Task { await database._stopObserving(id) }
                }
                if value == nil { finish() }
                return value
            } catch {
                finish()
                throw error
            }
        }

        private mutating func finish() {
            finished = true
            registration = nil
        }
    }
}

/// Removes its observer when the iterator holding it goes away.
final class Registration: Sendable {
    let database: Database
    let id: ObserverRegistry.ID

    init(database: Database, id: ObserverRegistry.ID) {
        self.database = database
        self.id = id
    }

    deinit {
        Task { [database, id] in await database._stopObserving(id) }
    }
}
