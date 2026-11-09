# SqlCipherKit

SqlCipherKit is a Swift wrapper around [SQLCipher](https://www.zetetic.net/sqlcipher/), providing an actor-isolated, encrypted SQLite database with lightweight ORM-like persistence and a composable query-builder API. It does not aim to be a full-featured ORM; instead it offers a thin, type-safe layer for common patterns — raw SQL execution, fluent SELECT/UPDATE/INSERT builders, and a `Codable`-backed `Entity` protocol for straightforward table mapping.

On Apple platforms (**macOS 10.15+, iOS 13+, visionOS 1+**) the library uses Apple's **CommonCrypto** framework as the cryptographic backend for SQLCipher, which requires no additional dependencies. On **Linux**, the OpenSSL crypto backend is used instead, which requires `libcrypto` to be available on the build machine (typically provided by `libssl-dev` on Debian/Ubuntu or `openssl-devel` on Fedora/RHEL).

---

## Requirements

| Platform | Minimum Version | Crypto backend | System prerequisite |
|---|---|---|---|
| macOS | 10.15 | CommonCrypto | None |
| iOS | 13 | CommonCrypto | None |
| visionOS | 1 | CommonCrypto | None |
| Linux | — | OpenSSL | `libssl-dev` / `openssl-devel` |

Building requires Swift 6.2 or later (Xcode 26 on Apple platforms).

---

## Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/BetterPractice/SqlCipherKit.git", from: "0.10.0"),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: ["SqlCipherKit"]
    ),
]
```

### Xcode Project

1. In Xcode, open **File → Add Package Dependencies…**
2. Enter `https://github.com/BetterPractice/SqlCipherKit` and select the version rule you want.
3. Add **SqlCipherKit** to the desired target.

---

## Usage

Open or create an encrypted database by providing a filesystem path and a passphrase. The passphrase is run through PBKDF2-HMAC-SHA512 by SQLCipher before use.

```swift
import SqlCipherKit

let db = try Database(path: "/path/to/store.db", key: "my-passphrase")
```

`Database` is a Swift actor, so all of its methods are called with `try await` when invoked from an async context.

An empty passphrase is rejected: SQLCipher treats an empty key as "no encryption", so plaintext is never produced by accident. Use the unencrypted initialiser below when plaintext is what you want.

### Raw keys

When you already hold a full-entropy 32-byte key (for example the output of a KDF you run yourself, or a key stored in the Keychain), pass it as `Data`. SQLCipher uses it directly and skips its own PBKDF2 stretching, so opening costs no key derivation. A database created with a raw key cannot be opened with a passphrase, or the reverse.

```swift
let key: Data = ...  // exactly 32 bytes
let db = try Database(path: "/path/to/store.db", rawKey: key)
try await db.rekey(rawKey: newKey)   // or db.rekey("a passphrase")
```

### Unencrypted databases

For data that is public or already ciphertext, `Database` can manage a plain SQLite file with the same API. No key is applied, the file is readable by any SQLite tool, `isEncrypted` is `false`, and `rekey` throws.

```swift
let db = try Database(unencryptedPath: "/path/to/public.db")
```

Opening an encrypted file this way throws `SqlCipherError.notPlaintextDatabase`; opening an unencrypted file with a key throws `SqlCipherError.keyFailed`.

### Journal mode

New databases use WAL by default. Pass `.rollback` for files that must stay a single file whenever no transaction is running, such as files copied between media, backed up as opaque blobs, or opened from read-only storage. The mode is fixed when the database is created: opening an existing file keeps its mode, whatever you pass, and `db.journalMode` reports the mode the file is in.

```swift
let db = try Database(path: "/path/to/store.db", key: "my-passphrase", journalMode: .rollback)
let pub = try Database(unencryptedPath: "/path/to/public.db", journalMode: .rollback)
```

### Raw SQL

For straightforward one-shot statements, pass SQL directly with `?` positional placeholders:

```swift
// DDL
try await db.execute("""
    CREATE TABLE IF NOT EXISTS products (
        id    INTEGER PRIMARY KEY,
        name  TEXT    NOT NULL,
        price REAL    NOT NULL
    )
""")

// Query
let rows = try await db.query(
    "SELECT id, name, price FROM products WHERE price < ? ORDER BY price",
    50.0
)
for row in rows {
    let name  = row.get("name",  as: String.self)
    let price = row.get("price", as: Double.self)
    print("\(name ?? "-"): \(price ?? 0)")
}

// Update
try await db.execute(
    "UPDATE products SET price = ? WHERE id = ?",
    39.99, 7
)
```

### Query Builder

The query builder separates the SQL template from the values bound at execution time, maximising reuse of SQLite's prepared-statement cache. Use `col(_:)` to reference columns and `Param<T>` for values supplied at the call site.

```swift
let products = TableName("products")
let idCol    = col("id")
let nameCol  = col("name")
let priceCol = col("price")

// Query — reusable template with named parameters
let maxPrice = Param<Double>("maxPrice")

let cheapProducts = Select(.all)
    .from(products)
    .where(priceCol < maxPrice)
    .orderBy(priceCol)

let rows = try await db.query(cheapProducts, maxPrice.set(50.0))

// Update — reusable template with named parameters
let newPrice = Param<Double>("newPrice")
let targetId = Param<Int>("id")

let updatePrice = Update(products)
    .set(priceCol, to: newPrice)
    .where(idCol == targetId)

try await db.execute(updatePrice, newPrice.set(39.99), targetId.set(7))
```

### Entity Protocol

Conform a `Codable` struct to `Entity` to get one-line save and fetch semantics. When the primary key is `Int?`, SQLite assigns the rowid on insert and the returned copy carries the generated value.

```swift
struct Product: Entity {
    static let tableName  = TableName("products")
    static let primaryKey: WritableKeyPath<Product, Int?> & Sendable = \.id

    var id:    Int?
    var name:  String
    var price: Double
}

// Insert — id is nil, SQLite assigns it
var product = Product(id: nil, name: "Widget", price: 9.99)
product = try await db.save(product)     // product.id is now Optional(1)

// Update — id is set, triggers an upsert
product.price = 7.49
try await db.save(product)

// Fetch all rows
let allProducts = try await db.fetch(Product.self)

// Fetch with an expression predicate
let affordable = try await db.fetch(
    Product.self,
    where: col("price") <= 10.0
)

// Fetch by primary key
if let found = try await db.fetchOne(Product.self, id: 1) {
    print(found.name)
}

// Delete by primary key, or by predicate; both return the number of rows deleted
try await db.delete(Product.self, id: 1)
try await db.delete(Product.self, where: col("price") > 100.0)
```

Saving an array (`db.save([a, b, c])`) is atomic: if one record fails, none are saved.

### Transactions

`transaction` runs a synchronous body inside `BEGIN` … `COMMIT`, rolling back if the body throws. The `Connection` it passes has the same raw-SQL, query-builder, and entity methods as `Database`, so they can all be combined atomically. Reads inside the body see its own uncommitted writes.

```swift
let order = try await db.transaction { conn in
    let order = try conn.save(Order(id: nil, customer: "Alice"))
    try conn.save(skus.map { LineItem(id: nil, orderID: order.id!, sku: $0) })
    try conn.execute("UPDATE customers SET orders = orders + 1 WHERE name = ?", "Alice")
    return order
}
```

Use `conn.savepoint { ... }` inside a transaction for a step that can fail and be undone without abandoning the rest. A batch `save([...])` already uses a savepoint, so it nests safely inside a transaction.

---

## Live Queries

A live query holds the result of a request and updates whenever a change to the database alters it. Describe what to observe with a `LiveRequest`:

| Request | Result | Before the first fetch |
|---|---|---|
| `.fetch(T.self, where:orderBy:limit:)` | `[T]` | `[]` |
| `.fetchOne(T.self, id:)` | `T?` | `nil` |
| `.count(T.self, where:)` | `Int` | `0` |
| `.exists(T.self, where:)` | `Bool` | `false` |
| `.sum`, `.min`, `.max` `(T.self, column, as:where:)` | `V?` | `nil` |
| `.avg(T.self, column, where:)` | `Double?` | `nil` |
| `.total(T.self, column, where:)` | `Double` | `0` |

`sum`, `min`, `max`, and `avg` are `nil` when no rows match, as in SQL. Use `total` when no rows should read as zero.

### In SwiftUI

`@Live` is available on iOS 14+, macOS 11+, and visionOS. Set the database once in the environment, then declare the result as a property:

```swift
@main
struct ShopApp: App {
    let db = try! Database(path: storePath, key: passphrase)

    var body: some Scene {
        WindowGroup {
            ProductList(maxPrice: 50).environment(\.database, db)
        }
    }
}

struct ProductList: View {
    @Live var products: [Product]
    @Live var count: Int

    init(maxPrice: Double) {
        _products = Live(
            .fetch(Product.self, where: col("price") < maxPrice, orderBy: col("name").ascending),
            animation: .default)
        _count = Live(.count(Product.self))
    }

    var body: some View {
        List(products, id: \.id) { Text($0.name) }
            .navigationTitle("\(count) products")
    }
}
```

- **Parameters.** When the view is re-created with a different request, for example a new `maxPrice`, the query runs again. Re-creating it with an equal request leaves the running observation alone, so creating a `Live` in `init` is cheap.
- **Placeholder first.** The property holds the request's placeholder until the first fetch completes.
- **Animation.** When `animation` is set, changes after the first value are applied with it. The first value is never animated.
- **Database changes.** If the environment's database changes, for example on sign-out, the property shows the placeholder until the new database delivers. It never shows the previous database's rows.

The projected value reports loading and errors. A missing `\.database` is reported as `LiveError.missingDatabase`, and a fetch that fails (for example because a table does not exist yet) stops observation until `retry()` is called:

```swift
if let error = $products.phase.error {
    Text("Couldn't load products: \(String(describing: error))")
    Button("Retry") { $products.retry() }
} else if $products.phase.isLoading {
    ProgressView()
}
```

### As an async sequence

On every platform, including Linux, `values(of:)` returns an `AsyncSequence` that yields the current value and then each change:

```swift
for try await products in db.values(of: .fetch(Product.self, orderBy: col("name").ascending)) {
    try await socket.send(JSONEncoder().encode(products))
}
```

The sequence is pull-based: commits only mark it dirty, and the query runs when the loop asks for the next value. A slow consumer receives the current state rather than a backlog. The query runs on the database actor and only the result is sent to the loop. The sequence ends when its task is cancelled, and throws if a fetch fails.

### How changes are detected

Every statement is checked when it is compiled for the tables it can write, including writes made by triggers and foreign-key cascades. When a transaction ends, observers of the tables it changed fetch again. A transaction produces one value. A write that leaves an observer's rows unchanged, such as an update to a row outside its `where` clause, produces none.

Limitations:

- **Only this `Database`'s writes are seen.** Changes made by another process (an app extension or widget, for example) or another connection to the same file are not detected.
- **Transactions left open across calls.** `transaction(_:)`, `savepoint(_:)`, batch `save([...])`, and migrations run as one call on the actor, so an observer never fetches while they are in progress. A transaction managed by hand with separate `execute("BEGIN")` and `execute("COMMIT")` calls is different: an observer may fetch between those calls and show uncommitted rows. It fetches again when the transaction ends, so a rollback is corrected. Use the transaction methods to avoid this.

---

## Migrations

SqlCipherKit includes a lightweight migration system for evolving your database schema over time. Each migration is a `struct` (or `class`) that conforms to the `Migration` protocol by providing a unique string `id`, an `up(_:)` method that applies the change, and an optional `down(_:)` method that reverses it.

```swift
struct CreateProductsTable: Migration {
    let id = "001-create-products"

    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            CreateTable(TableName("products"))
                .column("id",    .integer, .primaryKey)
                .column("name",  .text,    .notNull)
                .column("price", .real,    .notNull)
        )
    }

    func down(_ ctx: MigrationContext) throws {
        try ctx.execute(DropTable(TableName("products")))
    }
}

struct AddDiscountColumn: Migration {
    let id = "002-add-discount"

    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            AlterTable(TableName("products"), addColumn: "discount", .real, .default(0.0))
        )
    }

    func down(_ ctx: MigrationContext) throws {
        try ctx.execute(
            AlterTable(TableName("products"), dropColumn: "discount")
        )
    }
}
```

### Applying Migrations

Call `migrate(_:)` with an ordered array of all your migrations. The method creates a `_migrations` tracking table on first use and skips any migration whose `id` is already recorded there. Each pending migration runs inside its own transaction — if one fails, it is rolled back and no further migrations are applied.

```swift
let migrations: [any Migration] = [
    CreateProductsTable(),
    AddDiscountColumn(),
]

try await db.migrate(migrations)
```

It is safe to call `migrate(_:)` every time the app launches. Already-applied migrations are no-ops.

### Rolling Back

To reverse applied migrations, call `rollback(to:using:)` with the `id` of the earliest migration you want to undo. Every migration applied at or after that point is reversed in reverse order, each in its own transaction.

```swift
// Undo AddDiscountColumn and everything applied after it.
try await db.rollback(to: "002-add-discount", using: migrations)
```

---

## Notices

SqlCipherKit bundles the SQLCipher amalgamation source (`Sources/CSqlCipher/sqlite3.c`), which is distributed under a BSD-style license by Zetetic, LLC. See the [NOTICE](NOTICE) file for the full copyright and license text required by that license, and [LICENSE](LICENSE) for the MIT license that covers the Swift source in this repository.
