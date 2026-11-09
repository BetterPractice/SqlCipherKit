// MARK: - ObserverRegistry

/// The live observers of one ``Database``, and the hand-off between change
/// notifications and suspended ``LiveValues`` iterators.
///
/// Observation is **pull-based**: a notification never fetches anything.  It
/// either resumes an iterator that is waiting for a change, or marks a busy
/// one dirty so its next `next()` call fetches immediately.  However many
/// transactions commit while a consumer is busy, it fetches once.
///
/// Not `Sendable`: like ``StatementCache``, it is only touched on the owning
/// ``Database`` actor's executor.
final class ObserverRegistry {

    struct ID: Hashable, Sendable {
        fileprivate let raw: UInt64
    }

    /// What ``consume(_:)`` found.
    enum Status {
        /// A watched table changed since the last fetch.
        case changed
        /// Nothing changed yet; the caller should wait.
        case unchanged
        /// The observer was removed (cancelled or deallocated).
        case removed
    }

    private struct Entry {
        let tables: Set<String>
        var dirty = false
        /// Resumed with `true` on a change, `false` when the observer is removed.
        var waiter: CheckedContinuation<Bool, Never>?
        /// Raw values of the last rows delivered, for duplicate suppression.
        var lastRows: [[Value]]?
    }

    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 0

    var count: Int { entries.count }

    func register(tables: Set<String>) -> ID {
        nextID += 1
        entries[nextID] = Entry(tables: tables)
        return ID(raw: nextID)
    }

    /// Removes an observer, resuming it with "removed" if it is waiting.
    func unregister(_ id: ID) {
        entries.removeValue(forKey: id.raw)?.waiter?.resume(returning: false)
    }

    /// Wakes or marks dirty every observer watching one of `tables`.
    func notify(_ tables: Set<String>) {
        for (key, entry) in entries where !entry.tables.isDisjoint(with: tables) {
            if let waiter = entry.waiter {
                entries[key]?.waiter = nil
                waiter.resume(returning: true)
            } else {
                entries[key]?.dirty = true
            }
        }
    }

    /// Reports and clears the observer's dirty flag.
    func consume(_ id: ID) -> Status {
        guard let entry = entries[id.raw] else { return .removed }
        guard entry.dirty else { return .unchanged }
        entries[id.raw]?.dirty = false
        return .changed
    }

    /// Parks `continuation` until the next change or removal.  An observer
    /// removed in the meantime is resumed at once.
    func setWaiter(_ id: ID, _ continuation: CheckedContinuation<Bool, Never>) {
        guard entries[id.raw] != nil else {
            continuation.resume(returning: false)
            return
        }
        entries[id.raw]?.waiter = continuation
    }

    /// Stores `rows` as the observer's latest result and reports whether they
    /// differ from the previous one.
    func replaceRows(_ id: ID, with rows: [[Value]]) -> Bool {
        guard entries[id.raw]?.lastRows != rows else { return false }
        entries[id.raw]?.lastRows = rows
        return true
    }
}
