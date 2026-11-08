import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Shared test helpers

func tempDBPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sqlcipherkit-test-\(UUID().uuidString).db")
        .path
}

/// Records an issue unless `body` throws a ``SqlCipherError`` for which
/// `matches` returns `true`.
///
/// Written with `do` / `catch` instead of `#expect { … } throws: { … }`:
/// expanding that macro crashes the Swift 6.0 compiler.
func expectSqlCipherError(
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void,
    matching matches: (SqlCipherError) -> Bool
) async {
    do {
        try await body()
        Issue.record("Expected SqlCipherError.\(expected), but no error was thrown",
                     sourceLocation: sourceLocation)
    } catch let error as SqlCipherError where matches(error) {
        // expected
    } catch {
        Issue.record("Expected SqlCipherError.\(expected), got \(error)",
                     sourceLocation: sourceLocation)
    }
}
