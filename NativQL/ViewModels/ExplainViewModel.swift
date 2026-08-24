import Foundation
import NativQLKit
import Observation

/// Runs EXPLAIN (optionally ANALYZE) through the active connection's driver
/// and exposes the resulting plan tree for sheet rendering.
@MainActor
@Observable
final class ExplainViewModel {
    private(set) var plan: ExplainPlanNode?
    private(set) var errorText: String?
    private(set) var isLoading = false

    func run(sql: String, driver: any DatabaseDriver, analyze: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            plan = try await driver.explain(sql, analyze: analyze)
            errorText = nil
        } catch {
            plan = nil
            errorText = error.localizedDescription
        }
    }
}
