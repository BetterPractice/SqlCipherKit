#if canImport(SwiftUI)
import os
import SwiftUI

// MARK: - Environment

private struct DatabaseKey: EnvironmentKey {
    static let defaultValue: Database? = nil
}

extension EnvironmentValues {
    /// The database that ``Live`` properties in this view hierarchy read from.
    ///
    /// ```swift
    /// ContentView()
    ///     .environment(\.database, db)
    /// ```
    public var database: Database? {
        get { self[DatabaseKey.self] }
        set { self[DatabaseKey.self] = newValue }
    }
}

// MARK: - LivePhase

/// Where a ``Live`` property is in loading its value.
public enum LivePhase: Sendable {
    /// No value has arrived yet from the current database; the property
    /// holds the request's placeholder.
    case loading
    /// The property holds a fetched value and is following changes.
    case loaded
    /// Observation stopped.  The property keeps its last value, or the
    /// placeholder if none arrived.
    case failed(any Error)

    /// `true` while no value has arrived yet.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The error that stopped observation, if any.
    public var error: (any Error)? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// MARK: - LiveError

/// Errors reported through ``LivePhase/failed(_:)``.
public enum LiveError: Error, Sendable, CustomStringConvertible {
    /// No ``Database`` was set with `.environment(\.database, db)` above the view.
    case missingDatabase

    public var description: String {
        switch self {
        case .missingDatabase:
            return "No Database in the environment. "
                + "Set one with .environment(\\.database, db) above the view."
        }
    }
}

// MARK: - Live

/// A SwiftUI property that holds the result of a ``LiveRequest`` and updates
/// the view whenever a change to the database alters it.
///
/// ```swift
/// struct ProductList: View {
///     @Live var products: [Product]
///
///     init(maxPrice: Double) {
///         _products = Live(
///             .fetch(Product.self, where: col("price") < maxPrice, orderBy: col("name").ascending),
///             animation: .default)
///     }
///
///     var body: some View {
///         List(products, id: \.id) { Text($0.name) }
///     }
/// }
/// ```
///
/// The database comes from the environment: set it once with
/// `.environment(\.database, db)` near the root of the view hierarchy.
///
/// Behaviour:
///
/// - **Cheap to create.**  SwiftUI re-creates views often; a `Live` only
///   stores its request until SwiftUI installs it.  Observation is kept in
///   state that lives as long as the view's identity.
/// - **Parameters re-run the query.**  When a view is re-created with a
///   different request (for example a new `maxPrice`), the query runs again.
///   An equal request leaves the running observation alone.
/// - **Placeholder first.**  Until the first fetch completes, the property
///   holds the request's ``LiveRequest/placeholder`` (`[]`, `nil`, `0`, or
///   `false`), and ``Status/phase`` is ``LivePhase/loading``.
/// - **Animation.**  When `animation` is set, every change after the first
///   value is applied with it.  The first value from each database is never
///   animated.
/// - **Database changes.**  If the environment's database changes (for
///   example on sign-out), the property shows the placeholder until the new
///   database delivers a value; it never shows the previous database's rows.
/// - **Errors.**  A failed fetch, or a missing database, sets ``Status/phase``
///   to ``LivePhase/failed(_:)``.  Read it through the projected value:
///   `$products.phase`.  Call `$products.retry()` to start again.
///
/// See ``Database/values(of:)`` for how changes are detected, and its notes
/// on transactions and changes made by other processes.
@available(iOS 14.0, macOS 11.0, *)
@MainActor
@propertyWrapper
public struct Live<Result: Sendable>: @MainActor DynamicProperty {

    @Environment(\.database) private var database
    @StateObject private var box = LiveBox<Result>()

    private let request: LiveRequest<Result>
    private let animation: Animation?

    /// Creates a property that follows `request`.
    ///
    /// - Parameters:
    ///   - request:   What to observe.
    ///   - animation: The animation for changes after the first value.  `nil`
    ///                (the default) applies changes without animation.
    public init(_ request: LiveRequest<Result>, animation: Animation? = nil) {
        self.request = request
        self.animation = animation
    }

    /// The latest result, or the request's placeholder before the first one.
    public var wrappedValue: Result {
        box.value(for: database) ?? request.placeholder
    }

    /// The loading phase, and a way to retry after a failure.
    public var projectedValue: Status {
        Status(phase: box.phase(for: database), box: box)
    }

    public func update() {
        box.configure(database: database, request: request, animation: animation)
    }

    /// The state of a ``Live`` property, read through its projected value.
    @MainActor
    public struct Status {
        /// Where the property is in loading its value.
        public let phase: LivePhase
        fileprivate let box: LiveBox<Result>

        /// Starts observation again, for example after a failure caused by a
        /// table that a migration has since created.
        public func retry() {
            box.restart()
        }
    }
}

// MARK: - LiveBox

/// The state behind a ``Live`` property.  Kept in a `@StateObject` so it lives
/// as long as the view's identity, however often the view is re-created.
///
/// `configure` is called from `DynamicProperty.update()`, during a view
/// update, where publishing changes is not allowed.  It therefore never
/// changes published state itself: it only restarts the observation task, and
/// everything that affects the view is published from that task.
@available(iOS 14.0, macOS 11.0, *)
@MainActor
final class LiveBox<Result: Sendable>: ObservableObject {

    /// What the published state was fetched from.
    private struct Delivered {
        let value: Result
        let database: ObjectIdentifier
    }

    @Published private var delivered: Delivered?
    @Published private var failure: (any Error)?

    private var database: Database?
    private var request: LiveRequest<Result>?
    private var animation: Animation?
    private var task: Task<Void, Never>?
    /// Whether the current database has delivered a value; the first one is
    /// never animated.
    private var hasDelivered = false
    private var reportedMissingDatabase = false
    /// How many times observation has started.  Exposed for tests.
    private(set) var startCount = 0

    private static var logger: Logger {
        Logger(subsystem: "SqlCipherKit", category: "Live")
    }

    deinit {
        task?.cancel()
    }

    // MARK: Reading

    /// The latest value, if it came from `database`.
    func value(for database: Database?) -> Result? {
        guard let database, let delivered,
              delivered.database == ObjectIdentifier(database)
        else { return nil }
        return delivered.value
    }

    func phase(for database: Database?) -> LivePhase {
        guard let database else { return .failed(LiveError.missingDatabase) }
        if let failure { return .failed(failure) }
        return value(for: database) == nil ? .loading : .loaded
    }

    // MARK: Driving

    /// Starts, restarts, or leaves alone the observation, depending on whether
    /// the database or request changed.  Called on every view update.
    func configure(database: Database?, request: LiveRequest<Result>, animation: Animation?) {
        self.animation = animation
        guard database !== self.database || request != self.request else { return }
        if database !== self.database { hasDelivered = false }
        self.database = database
        self.request = request
        restart()
    }

    /// Cancels any running observation and starts a new one.
    func restart() {
        task?.cancel()
        task = nil
        guard let request else { return }
        guard let database else {
            if !reportedMissingDatabase {
                reportedMissingDatabase = true
                Self.logger.error("\(LiveError.missingDatabase.description, privacy: .public)")
            }
            return
        }
        startCount += 1
        task = Task { [weak self] in
            self?.failure = nil
            do {
                for try await value in database.values(of: request) {
                    guard let self, !Task.isCancelled else { return }
                    self.deliver(value, from: database)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failure = error
            }
        }
    }

    private func deliver(_ value: Result, from database: Database) {
        let update = Delivered(value: value, database: ObjectIdentifier(database))
        if hasDelivered, let animation {
            withAnimation(animation) { delivered = update }
        } else {
            delivered = update
        }
        hasDelivered = true
    }
}
#endif
