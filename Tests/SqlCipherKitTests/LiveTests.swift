#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Testing

@testable import SqlCipherKit

// Exercises `LiveBox`, the state behind the `@Live` property wrapper, by
// driving it the way `DynamicProperty.update()` does.  Rendering is SwiftUI's
// job; what matters here is which value and phase a view would read.

private struct Item: Entity, Equatable {
    var id: Int?
    var name: String

    static let tableName = TableName("items")
    static let primaryKey: WritableKeyPath<Item, Int?> & Sendable = \.id
}

private func makeDB(createTable: Bool = true) async throws -> Database {
    let db = try Database(path: tempDBPath(), key: "testkey")
    if createTable {
        try await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    }
    return db
}

private let allItems = LiveRequest.fetch(Item.self, orderBy: col("name").ascending)

/// Polls `condition` on the main actor until it holds, failing after about two seconds.
@MainActor
private func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Condition not met in time", sourceLocation: sourceLocation)
}

@Suite("Live property state")
@MainActor
struct LiveBoxTests {

    @available(iOS 14.0, macOS 11.0, *)
    @Test("Loads the first value, then follows changes")
    func loadsAndFollows() async throws {
        let db = try await makeDB()
        let box = LiveBox<[Item]>()
        box.configure(database: db, request: allItems, animation: nil)
        #expect(box.phase(for: db).isLoading)
        #expect(box.value(for: db) == nil)

        try await waitUntil { box.value(for: db) == [] }
        #expect(!box.phase(for: db).isLoading)
        #expect(box.phase(for: db).error == nil)

        try await db.save(Item(id: nil, name: "Apple"))
        try await waitUntil { box.value(for: db)?.map(\.name) == ["Apple"] }
    }

    @available(iOS 14.0, macOS 11.0, *)
    @Test("An equal request leaves the observation running; a new one restarts it")
    func requestChanges() async throws {
        let db = try await makeDB()
        try await db.save([Item(id: nil, name: "Apple"), Item(id: nil, name: "Banana")])
        let box = LiveBox<[Item]>()

        func request(_ prefix: String) -> LiveRequest<[Item]> {
            .fetch(Item.self, where: col("name").like("\(prefix)%"))
        }

        box.configure(database: db, request: request("A"), animation: nil)
        try await waitUntil { box.value(for: db)?.map(\.name) == ["Apple"] }

        // SwiftUI calls update() on every view update with an equal request.
        box.configure(database: db, request: request("A"), animation: .default)
        #expect(box.startCount == 1)

        box.configure(database: db, request: request("B"), animation: nil)
        #expect(box.startCount == 2)
        try await waitUntil { box.value(for: db)?.map(\.name) == ["Banana"] }
    }

    @available(iOS 14.0, macOS 11.0, *)
    @Test("A missing database is reported as a failure")
    func missingDatabase() {
        let box = LiveBox<[Item]>()
        box.configure(database: nil, request: allItems, animation: nil)
        #expect(box.value(for: nil) == nil)
        #expect(box.phase(for: nil).error is LiveError)
        #expect(box.startCount == 0)
    }

    @available(iOS 14.0, macOS 11.0, *)
    @Test("A new database never shows the previous database's rows")
    func databaseSwap() async throws {
        let first = try await makeDB()
        let second = try await makeDB()
        try await first.save(Item(id: nil, name: "From first"))
        try await second.save(Item(id: nil, name: "From second"))

        let box = LiveBox<[Item]>()
        box.configure(database: first, request: allItems, animation: nil)
        try await waitUntil { box.value(for: first)?.first?.name == "From first" }

        box.configure(database: second, request: allItems, animation: nil)
        // Before the second database delivers, the view reads the placeholder.
        #expect(box.value(for: second) == nil)
        #expect(box.phase(for: second).isLoading)
        try await waitUntil { box.value(for: second)?.first?.name == "From second" }
    }

    @available(iOS 14.0, macOS 11.0, *)
    @Test("A failed fetch is reported, and retry recovers")
    func failureAndRetry() async throws {
        let db = try await makeDB(createTable: false)
        let box = LiveBox<[Item]>()
        box.configure(database: db, request: allItems, animation: nil)
        try await waitUntil { box.phase(for: db).error != nil }
        #expect(box.phase(for: db).error is SqlCipherError)

        try await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try await db.save(Item(id: nil, name: "Apple"))
        box.restart()
        try await waitUntil { box.value(for: db)?.map(\.name) == ["Apple"] }
        #expect(box.phase(for: db).error == nil)
    }

    @available(iOS 14.0, macOS 11.0, *)
    @Test("Releasing the state stops its observation")
    func releaseStopsObserving() async throws {
        let db = try await makeDB()
        do {
            let box = LiveBox<[Item]>()
            box.configure(database: db, request: allItems, animation: nil)
            try await waitUntil { box.value(for: db) == [] }
            #expect(await db._observerCount == 1)
        }
        for _ in 0..<200 where await db._observerCount != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await db._observerCount == 0)
    }
}
// MARK: - Call site

// Compile-only: the intended way to use `@Live` from a view.  If this stops
// compiling, the public API has changed shape.
@available(iOS 14.0, macOS 11.0, *)
private struct ItemList: View {
    @Live var items: [Item]
    @Live var count: Int

    init(prefix: String) {
        _items = Live(
            .fetch(Item.self, where: col("name").like("\(prefix)%"), orderBy: col("name").ascending),
            animation: .default)
        _count = Live(.count(Item.self))
    }

    var body: some View {
        VStack {
            if let error = $items.phase.error {
                Text("Failed: \(String(describing: error))")
                Button("Retry") { $items.retry() }
            } else if $items.phase.isLoading {
                ProgressView()
            } else {
                Text("\(count) items")
                ForEach(items, id: \.id) { Text($0.name) }
            }
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
@MainActor
private func makeRoot(_ db: Database) -> some View {
    ItemList(prefix: "A").environment(\.database, db)
}
#endif
