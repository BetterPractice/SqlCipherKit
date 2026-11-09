// MARK: - SortTerm

/// One ORDER BY term for a ``LiveRequest``.
///
/// ```swift
/// .fetch(Product.self, orderBy: col("price").descending, col("name").ascending)
/// ```
public struct SortTerm: Sendable, Hashable {
    public let column: ColumnRef
    public let direction: SortDirection

    public init(_ column: ColumnRef, _ direction: SortDirection = .ascending) {
        self.column = column
        self.direction = direction
    }
}

extension ColumnRef {
    /// This column, sorted in ascending order.
    public var ascending: SortTerm { SortTerm(self, .ascending) }
    /// This column, sorted in descending order.
    public var descending: SortTerm { SortTerm(self, .descending) }
}

// MARK: - LiveRequest

/// A description of a value to observe: an entity fetch or a scalar aggregate
/// over one entity's table.
///
/// Requests are values.  Two requests are equal when they render to the same
/// SQL with the same bindings, so a view can rebuild its request on every
/// update and only a real change (for example a new parameter value) starts
/// a new observation.
///
/// ```swift
/// for try await products in db.values(of: .fetch(Product.self, where: col("price") < 50)) {
///     …
/// }
/// ```
public struct LiveRequest<Result: Sendable>: Sendable {

    /// The SQL the request runs.
    let query: BuiltQuery
    /// Lowercased names of the tables the query reads.
    let tables: Set<String>
    /// Identity for equality: the SQL plus its bindings as `Value`s.
    let key: Key
    /// Turns fetched rows into the result.
    let decode: @Sendable ([Row], ComplexColumnStrategy?) throws -> Result

    /// The value to show before the first fetch completes: `[]` for
    /// ``fetch(_:where:orderBy:limit:)``, `nil` for ``fetchOne(_:id:)`` and the
    /// optional aggregates, `0` for ``count(_:where:)``, `false` for
    /// ``exists(_:where:)``.
    public let placeholder: Result

    struct Key: Hashable, Sendable {
        let sql: String
        let bindings: [String: Value]
    }

    init(
        query: BuiltQuery,
        table: TableName,
        placeholder: Result,
        decode: @escaping @Sendable ([Row], ComplexColumnStrategy?) throws -> Result
    ) {
        self.query = query
        self.tables = [table.name.lowercased()]
        self.key = Key(sql: query.sql, bindings: query.bindings.mapValues(\.sqlValue))
        self.placeholder = placeholder
        self.decode = decode
    }
}

extension LiveRequest: Equatable {
    public static func == (lhs: LiveRequest, rhs: LiveRequest) -> Bool {
        lhs.key == rhs.key
    }
}

extension LiveRequest: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

// MARK: - Entity requests

extension LiveRequest {

    /// Observes the rows of `T`'s table that match `predicate`, in the given order.
    public static func fetch<T: Entity>(
        _ type: T.Type,
        where predicate: Expression? = nil,
        orderBy ordering: SortTerm...,
        limit: Int? = nil
    ) -> LiveRequest<[T]> where Result == [T] {
        var select = Select(.all).from(T.tableName)
        if let predicate { select = select.where(predicate) }
        for term in ordering { select = select.orderBy(term.column, term.direction) }
        if let limit { select = select.limit(limit) }
        let query = select.build()
        return LiveRequest(query: query, table: T.tableName, placeholder: []) { rows, strategy in
            try decodeEntities(T.self, rows, strategy)
        }
    }

    /// Observes the row of `T`'s table whose primary key is `id`; `nil` while
    /// no such row exists.
    public static func fetchOne<T: Entity>(
        _ type: T.Type,
        id: T.ID
    ) -> LiveRequest<T?> where Result == T? {
        let select = Select(.all).from(T.tableName)
            .where(.compare(ColumnRef(T.primaryKeyName), .eq, .literal(id)))
            .limit(1)
        let query = select.build()
        return LiveRequest(query: query, table: T.tableName, placeholder: nil) { rows, strategy in
            try decodeEntities(T.self, rows, strategy).first
        }
    }

    private static func decodeEntities<T: Entity>(
        _ type: T.Type,
        _ rows: [Row],
        _ strategy: ComplexColumnStrategy?
    ) throws -> [T] {
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = strategy
        return try decoder.decode(T.self, from: rows)
    }
}

// MARK: - Scalar requests

extension LiveRequest {

    /// Observes the number of rows in `T`'s table that match `predicate`.
    public static func count<T: Entity>(
        _ type: T.Type,
        where predicate: Expression? = nil
    ) -> LiveRequest<Int> where Result == Int {
        scalar("COUNT(*)", T.tableName, predicate, placeholder: 0) { Int.from(sqlValue: $0) ?? 0 }
    }

    /// Observes whether any row in `T`'s table matches `predicate`.
    public static func exists<T: Entity>(
        _ type: T.Type,
        where predicate: Expression? = nil
    ) -> LiveRequest<Bool> where Result == Bool {
        // `COUNT(*) > 0 … LIMIT 1` would scan; EXISTS stops at the first row.
        var ctx = RenderContext()
        var inner = "SELECT 1 FROM \(T.tableName.fromSQL)"
        if let predicate { inner += " WHERE \(predicate.render(into: &ctx))" }
        let query = BuiltQuery(sql: "SELECT EXISTS(\(inner))", bindings: ctx.bindings)
        return LiveRequest(query: query, table: T.tableName, placeholder: false) { rows, _ in
            rows.first.flatMap { Bool.from(sqlValue: $0[0]) } ?? false
        }
    }

    /// Observes `SUM(column)`; `nil` when no rows match.
    public static func sum<T: Entity, V: SQLConvertible>(
        _ type: T.Type,
        _ column: ColumnRef,
        as valueType: V.Type = V.self,
        where predicate: Expression? = nil
    ) -> LiveRequest<V?> where Result == V? {
        optionalAggregate("SUM", column, T.tableName, predicate)
    }

    /// Observes `MIN(column)`; `nil` when no rows match.
    public static func min<T: Entity, V: SQLConvertible>(
        _ type: T.Type,
        _ column: ColumnRef,
        as valueType: V.Type = V.self,
        where predicate: Expression? = nil
    ) -> LiveRequest<V?> where Result == V? {
        optionalAggregate("MIN", column, T.tableName, predicate)
    }

    /// Observes `MAX(column)`; `nil` when no rows match.
    public static func max<T: Entity, V: SQLConvertible>(
        _ type: T.Type,
        _ column: ColumnRef,
        as valueType: V.Type = V.self,
        where predicate: Expression? = nil
    ) -> LiveRequest<V?> where Result == V? {
        optionalAggregate("MAX", column, T.tableName, predicate)
    }

    /// Observes `AVG(column)`; `nil` when no rows match.
    public static func avg<T: Entity>(
        _ type: T.Type,
        _ column: ColumnRef,
        where predicate: Expression? = nil
    ) -> LiveRequest<Double?> where Result == Double? {
        optionalAggregate("AVG", column, T.tableName, predicate)
    }

    /// Observes SQLite's `TOTAL(column)`: the sum as a `Double`, `0` when no
    /// rows match.  Use it when "no rows" should read as zero.
    public static func total<T: Entity>(
        _ type: T.Type,
        _ column: ColumnRef,
        where predicate: Expression? = nil
    ) -> LiveRequest<Double> where Result == Double {
        scalar("TOTAL(\(column.sqlName))", T.tableName, predicate, placeholder: 0) {
            Double.from(sqlValue: $0) ?? 0
        }
    }

    private static func optionalAggregate<V: SQLConvertible>(
        _ function: String,
        _ column: ColumnRef,
        _ table: TableName,
        _ predicate: Expression?
    ) -> LiveRequest<V?> where Result == V? {
        scalar("\(function)(\(column.sqlName))", table, predicate, placeholder: nil) {
            V.from(sqlValue: $0)
        }
    }

    /// A single-value request: `SELECT <expression> FROM <table> [WHERE …]`.
    private static func scalar(
        _ expression: String,
        _ table: TableName,
        _ predicate: Expression?,
        placeholder: Result,
        convert: @escaping @Sendable (Value) -> Result
    ) -> LiveRequest {
        var ctx = RenderContext()
        var sql = "SELECT \(expression) FROM \(table.fromSQL)"
        if let predicate { sql += " WHERE \(predicate.render(into: &ctx))" }
        let query = BuiltQuery(sql: sql, bindings: ctx.bindings)
        return LiveRequest(query: query, table: table, placeholder: placeholder) { rows, _ in
            convert(rows.first?[0] ?? .null)
        }
    }
}
