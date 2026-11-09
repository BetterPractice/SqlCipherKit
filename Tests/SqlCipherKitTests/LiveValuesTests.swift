import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Fixtures

private struct Product: Entity, Equatable {
    var id: Int?
    var name: String
    var price: Double

    static let tableName = TableName("products")
    static let primaryKey: WritableKeyPath<Product, Int?> & Sendable = \.id
}

private struct Review: Entity, Equatable {
    var id: Int?
    var productID: Int
    var stars: Int

    static let tableName = TableName("reviews")
    static let primaryKey: WritableKeyPath<Review, Int?> & Sendable = \.id

    enum CodingKeys: String, CodingKey {
        case id
        case productID = "product_id"
        case stars
    }
}

private func makeDB() async throws -> Database {
    let db = try Database(path: tempDBPath(), key: "testkey")
    try await db.execute("PRAGMA foreign_keys = ON")
    try await db.execute(
        "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL)")
    try await db.execute(
        """
        CREATE TABLE reviews (
            id INTEGER PRIMARY KEY,
            product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            stars INTEGER NOT NULL
        )
        """)
    try await db.execute("CREATE TABLE audit (id INTEGER PRIMARY KEY, note TEXT)")
    return db
}

private func names(_ products: [Product]?) -> [String]? {
    products?.map(\.name)
}

private let byName = col("name").ascending

// MARK: - Entity fetches

@Suite("Live values: entity fetches")
struct LiveEntityFetchTests {

    @Test("Delivers the current value first")
    func initialValue() async throws {
        let db = try await makeDB()
        try await db.save(Product(id: nil, name: "Apple", price: 1))

        var values = db.values(of: .fetch(Product.self, orderBy: byName)).makeAsyncIterator()
        #expect(names(try await values.next()) == ["Apple"])
    }

    @Test("Delivers inserts, updates and deletes")
    func rowChanges() async throws {
        let db = try await makeDB()
        var values = db.values(of: .fetch(Product.self, orderBy: byName)).makeAsyncIterator()
        #expect(names(try await values.next()) == [])

        let apple = try await db.save(Product(id: nil, name: "Apple", price: 1))
        #expect(names(try await values.next()) == ["Apple"])

        try await db.save(Product(id: apple.id, name: "Apricot", price: 1))
        #expect(names(try await values.next()) == ["Apricot"])

        try await db.delete(Product.self, id: apple.id!)
        #expect(names(try await values.next()) == [])
    }

    @Test("Skips writes that leave the result unchanged")
    func duplicateSuppression() async throws {
        let db = try await makeDB()
        let cheap = col("price") < 10.0
        var values = db.values(of: .fetch(Product.self, where: cheap, orderBy: byName))
            .makeAsyncIterator()
        #expect(names(try await values.next()) == [])

        // Same table, outside the predicate: must not produce a value.
        try await db.save(Product(id: nil, name: "Truffle", price: 500))
        // An UPDATE that matches no rows.
        try await db.execute("UPDATE products SET price = 1 WHERE id = 999")
        // Then a relevant change.  If either write above leaked through, the
        // next value would be a duplicate `[]` instead of this one.
        try await db.save(Product(id: nil, name: "Apple", price: 1))
        #expect(names(try await values.next()) == ["Apple"])
    }

    @Test("Ignores writes to unrelated tables")
    func unrelatedTables() async throws {
        let db = try await makeDB()
        var values = db.values(of: .fetch(Product.self, orderBy: byName)).makeAsyncIterator()
        #expect(names(try await values.next()) == [])

        try await db.execute("INSERT INTO audit (note) VALUES ('x')")
        try await db.save(Product(id: nil, name: "Apple", price: 1))
        #expect(names(try await values.next()) == ["Apple"])
    }

    @Test("fetchOne follows a single row, including its deletion")
    func fetchOne() async throws {
        let db = try await makeDB()
        let apple = try await db.save(Product(id: nil, name: "Apple", price: 1))
        var values = db.values(of: .fetchOne(Product.self, id: apple.id!)).makeAsyncIterator()
        #expect(try await values.next() == apple)

        try await db.save(Product(id: nil, name: "Banana", price: 2))  // other row
        try await db.save(Product(id: apple.id, name: "Apple", price: 3))
        #expect(try await values.next()??.price == 3)

        try await db.delete(Product.self, id: apple.id!)
        let deleted: Product?? = try await values.next()
        #expect(deleted == .some(nil))
    }
}

// MARK: - Transactions and coalescing

@Suite("Live values: transactions")
struct LiveTransactionTests {

    @Test("A transaction produces one value with its final state")
    func transactionIsOneValue() async throws {
        let db = try await makeDB()
        var values = db.values(of: .fetch(Product.self, orderBy: byName)).makeAsyncIterator()
        #expect(names(try await values.next()) == [])

        try await db.transaction { conn in
            try conn.save(Product(id: nil, name: "Apple", price: 1))
            try conn.save(Product(id: nil, name: "Banana", price: 2))
        }
        #expect(names(try await values.next()) == ["Apple", "Banana"])

        try await db.save(Product(id: nil, name: "Cherry", price: 3))
        #expect(names(try await values.next()) == ["Apple", "Banana", "Cherry"])
    }

    @Test("A rolled-back transaction produces no value")
    func rollback() async throws {
        let db = try await makeDB()
        var values = db.values(of: .fetch(Product.self, orderBy: byName)).makeAsyncIterator()
        #expect(names(try await values.next()) == [])

        struct Abort: Error {}
        do {
            try await db.transaction { conn in
                try conn.save(Product(id: nil, name: "Ghost", price: 1))
                throw Abort()
            }
        } catch is Abort {}

        try await db.save(Product(id: nil, name: "Apple", price: 1))
        #expect(names(try await values.next()) == ["Apple"])
    }

    @Test("A manual transaction across actor calls is reported at COMMIT")
    func manualTransaction() async throws {
        let db = try await makeDB()
        var values = db.values(of: .count(Product.self)).makeAsyncIterator()
        #expect(try await values.next() == 0)

        try await db.execute("BEGIN")
        try await db.save(Product(id: nil, name: "Apple", price: 1))
        try await db.save(Product(id: nil, name: "Banana", price: 2))
        try await db.execute("COMMIT")
        #expect(try await values.next() == 2)
    }

    @Test("Commits made while the consumer is busy coalesce into one value")
    func coalescing() async throws {
        let db = try await makeDB()
        var values = db.values(of: .count(Product.self)).makeAsyncIterator()
        #expect(try await values.next() == 0)

        for i in 1...20 {
            try await db.save(Product(id: nil, name: "P\(i)", price: Double(i)))
        }
        // One pull sees the latest state, not 1, 2, 3, …
        #expect(try await values.next() == 20)

        try await db.save(Product(id: nil, name: "P21", price: 21))
        #expect(try await values.next() == 21)
    }
}

// MARK: - Change detection coverage

@Suite("Live values: change detection")
struct LiveChangeDetectionTests {

    @Test("Raw SQL writes are detected")
    func rawSQL() async throws {
        let db = try await makeDB()
        var values = db.values(of: .count(Product.self)).makeAsyncIterator()
        #expect(try await values.next() == 0)

        try await db.execute("INSERT INTO products (name, price) VALUES ('Apple', 1)")
        #expect(try await values.next() == 1)
    }

    @Test("Writes made by a trigger are detected")
    func triggers() async throws {
        let db = try await makeDB()
        try await db.execute(
            """
            CREATE TRIGGER audit_to_products AFTER INSERT ON audit BEGIN
                INSERT INTO products (name, price) VALUES (NEW.note, 0);
            END
            """)
        var values = db.values(of: .count(Product.self)).makeAsyncIterator()
        #expect(try await values.next() == 0)

        try await db.execute("INSERT INTO audit (note) VALUES ('Via trigger')")
        #expect(try await values.next() == 1)
    }

    @Test("Foreign-key cascades are detected")
    func cascades() async throws {
        let db = try await makeDB()
        let apple = try await db.save(Product(id: nil, name: "Apple", price: 1))
        try await db.save(Review(id: nil, productID: apple.id!, stars: 5))

        var values = db.values(of: .count(Review.self)).makeAsyncIterator()
        #expect(try await values.next() == 1)

        try await db.delete(Product.self, id: apple.id!)  // cascades to reviews
        #expect(try await values.next() == 0)
    }

    @Test("DELETE without WHERE (the truncate optimisation) is detected")
    func truncate() async throws {
        let db = try await makeDB()
        try await db.save(Product(id: nil, name: "Apple", price: 1))
        var values = db.values(of: .count(Product.self)).makeAsyncIterator()
        #expect(try await values.next() == 1)

        try await db.execute("DELETE FROM products")
        #expect(try await values.next() == 0)
    }

    @Test("Dropping an observed table ends the sequence with an error")
    func dropTable() async throws {
        let db = try await makeDB()
        try await db.execute("DROP TABLE reviews")  // FK references products
        var values = db.values(of: .count(Product.self)).makeAsyncIterator()
        #expect(try await values.next() == 0)

        try await db.execute("DROP TABLE products")
        do {
            _ = try await values.next()
            Issue.record("Expected the fetch to fail after DROP TABLE")
        } catch is SqlCipherError {
            // expected
        }
        #expect(try await values.next() == nil)
    }
}

// MARK: - Scalars

@Suite("Live values: scalars")
struct LiveScalarTests {

    @Test("count and exists")
    func countAndExists() async throws {
        let db = try await makeDB()
        let pricey = col("price") > 100.0
        var count = db.values(of: .count(Product.self, where: pricey)).makeAsyncIterator()
        var exists = db.values(of: .exists(Product.self, where: pricey)).makeAsyncIterator()
        #expect(try await count.next() == 0)
        #expect(try await exists.next() == false)

        try await db.save(Product(id: nil, name: "Truffle", price: 500))
        #expect(try await count.next() == 1)
        #expect(try await exists.next() == true)
    }

    @Test("Optional aggregates are nil over no rows; total is zero")
    func aggregates() async throws {
        let db = try await makeDB()
        var sum = db.values(of: .sum(Product.self, col("price"), as: Double.self))
            .makeAsyncIterator()
        var maxPrice = db.values(of: .max(Product.self, col("price"), as: Double.self))
            .makeAsyncIterator()
        var total = db.values(of: .total(Product.self, col("price"))).makeAsyncIterator()

        #expect(try await sum.next() == .some(nil))
        #expect(try await maxPrice.next() == .some(nil))
        #expect(try await total.next() == 0)

        try await db.save(Product(id: nil, name: "Apple", price: 1.5))
        try await db.save(Product(id: nil, name: "Banana", price: 2.5))
        #expect(try await sum.next() == 4.0)
        #expect(try await maxPrice.next() == 2.5)
        #expect(try await total.next() == 4.0)
    }
}

// MARK: - Requests and lifetime

@Suite("Live values: requests and lifetime")
struct LiveRequestLifetimeTests {

    @Test("Requests are equal exactly when their SQL and bindings match")
    func requestEquality() {
        let a = LiveRequest.fetch(Product.self, where: col("price") < 10.0, orderBy: byName)
        let b = LiveRequest.fetch(Product.self, where: col("price") < 10.0, orderBy: byName)
        let c = LiveRequest.fetch(Product.self, where: col("price") < 20.0, orderBy: byName)
        let d = LiveRequest.fetch(Product.self, where: col("price") < 10.0)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("Placeholders match each request kind")
    func placeholders() {
        #expect(LiveRequest.fetch(Product.self).placeholder == [])
        #expect(LiveRequest.fetchOne(Product.self, id: 1).placeholder == nil)
        #expect(LiveRequest.count(Product.self).placeholder == 0)
        #expect(LiveRequest.exists(Product.self).placeholder == false)
        #expect(LiveRequest.avg(Product.self, col("price")).placeholder == nil)
    }

    @Test("Cancelling the consuming task ends the sequence and removes the observer")
    func cancellation() async throws {
        let db = try await makeDB()
        let started = AsyncStream<Void>.makeStream()

        let consumer = Task {
            var received = 0
            for try await _ in db.values(of: .count(Product.self)) {
                received += 1
                started.continuation.yield()
            }
            return received
        }

        for await _ in started.stream { break }  // first value delivered; now waiting
        #expect(await db._observerCount == 1)

        consumer.cancel()
        #expect(try await consumer.value == 1)
        try await waitUntil { await db._observerCount == 0 }
    }

    @Test("Dropping an iterator removes its observer")
    func iteratorDeinit() async throws {
        let db = try await makeDB()
        do {
            var values = db.values(of: .count(Product.self)).makeAsyncIterator()
            _ = try await values.next()
            #expect(await db._observerCount == 1)
        }
        try await waitUntil { await db._observerCount == 0 }
    }
}

/// Polls `condition` until it holds, failing after about two seconds.
private func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Condition not met in time", sourceLocation: sourceLocation)
}
