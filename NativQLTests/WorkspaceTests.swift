import XCTest
import NativQLKit
@testable import NativQL

/// Minimal DatabaseDriver double: everything fatal-errors except execute /
/// browseRows, which return canned results and record every call.
final class FakeDriver: DatabaseDriver, @unchecked Sendable {
    let kind = DatabaseKind.postgres

    var executeResult: Result<QueryResult, Error> = .success(QueryResult(
        columns: [], rows: [], executionMilliseconds: 0, statementType: .other
    ))
    var browseResult: Result<RowPage, Error> = .success(RowPage(columns: [], rows: []))
    var explainResult: Result<ExplainPlanNode, Error> = .success(ExplainPlanNode(operation: "Seq Scan"))

    private(set) var executedSQLs: [String] = []
    private(set) var browseCalls: [(table: TableRef, sort: SortSpec?, limit: Int, offset: Int)] = []
    private(set) var explainCalls: [(sql: String, analyze: Bool)] = []

    func execute(_ sql: String) async throws -> QueryResult {
        executedSQLs.append(sql)
        return try executeResult.get()
    }

    func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage {
        browseCalls.append((table, sort, limit, offset))
        return try browseResult.get()
    }

    func isConnected() async -> Bool { true }
    func cancelRunningQuery() async {}

    // Untouched by workspace logic.
    func connect(_ config: ConnectionConfig) async throws { fatalError("unused") }
    func disconnect() async { fatalError("unused") }
    func listDatabases() async throws -> [DatabaseInfo] { fatalError("unused") }
    func listTables(database: String, schema: String?) async throws -> [TableInfo] { fatalError("unused") }
    func listColumns(_ table: TableRef) async throws -> [ColumnInfo] { fatalError("unused") }
    func primaryKey(of table: TableRef) async throws -> [String]? { fatalError("unused") }
    func tableDDL(_ table: TableRef) async throws -> String { fatalError("unused") }
    func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode {
        explainCalls.append((sql, analyze))
        return try explainResult.get()
    }
    func createDatabase(named: String) async throws { fatalError("unused") }
    func dropDatabase(named: String) async throws { fatalError("unused") }
    func executeMutation(_ statement: MutationStatement) async throws -> Int64 { fatalError("unused") }
}

enum FakeQueryError: LocalizedError {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message): return message
        }
    }
}

/// DriverProviding double with explicit connectivity control per connection id.
final class FakeDriverProvider: DriverProviding {
    private(set) var drivers: [UUID: any DatabaseDriver] = [:]
    private(set) var connectedIds: Set<UUID> = []

    func install(_ driver: any DatabaseDriver, for id: UUID, connected: Bool = true) {
        drivers[id] = driver
        if connected {
            connectedIds.insert(id)
        } else {
            connectedIds.remove(id)
        }
    }

    func driver(for id: UUID) -> (any DatabaseDriver)? {
        drivers[id]
    }

    func isConnected(_ id: UUID) async -> Bool {
        connectedIds.contains(id)
    }
}

@MainActor
final class WorkspaceTests: XCTestCase {
    private let connectionId = UUID()

    private func makeFixture(
        executeResult: Result<QueryResult, Error> = .success(QueryResult(
            columns: [ColumnInfo(name: "n", dataType: "int4")],
            rows: [[.int(1)]],
            executionMilliseconds: 1,
            statementType: .select
        )),
        browseResult: Result<RowPage, Error>? = nil
    ) -> (WorkspaceViewModel, FakeDriver, FakeDriverProvider) {
        let provider = FakeDriverProvider()
        let driver = FakeDriver()
        driver.executeResult = executeResult
        if let browseResult {
            driver.browseResult = browseResult
        }
        provider.install(driver, for: connectionId)
        let vm = WorkspaceViewModel(drivers: provider)
        return (vm, driver, provider)
    }

    private func openBrowseTab(
        _ vm: WorkspaceViewModel,
        pageSize: Int? = nil,
        estimate: Int64? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UUID {
        let ref = TableRef(database: "shop", name: "users")
        let tab = vm.openBrowseTable(ref, connectionId: connectionId)
        vm.setPageSize(pageSize ?? 200, for: tab.id)
        vm.setTotalEstimate(estimate, for: tab.id)
        XCTAssertEqual(vm.activeTabId, tab.id, file: file, line: line)
        return tab.id
    }

    // MARK: - Run text resolution

    func testRunUsesSelectionRangeWhenSet() async throws {
        let (vm, driver, _) = makeFixture()
        let tab = vm.openQueryTab(connectionId: connectionId)
        let fullText = "SELECT 1;\nSELECT 2;"
        vm.setEditorText(fullText, for: tab.id)
        let nsText = fullText as NSString
        let range = nsText.range(of: "SELECT 2;")
        vm.setSelection(start: range.location, end: range.location + range.length, for: tab.id)

        await vm.runActive()

        XCTAssertEqual(driver.executedSQLs, ["SELECT 2;"])
        guard case .loaded = vm.activeTab?.result else {
            return XCTFail("expected loaded result, got \(String(describing: vm.activeTab?.result))")
        }
    }

    func testRunUsesFullTextWhenSelectionEmpty() async throws {
        let (vm, driver, _) = makeFixture()
        let tab = vm.openQueryTab(connectionId: connectionId)
        vm.setEditorText("SELECT 1; SELECT 2;", for: tab.id)
        vm.setSelection(start: 5, end: 5, for: tab.id)

        await vm.runActive()

        XCTAssertEqual(driver.executedSQLs, ["SELECT 1; SELECT 2;"])
    }

    func testRunEmptyTextIsNoOp() async throws {
        let (vm, driver, _) = makeFixture()
        let tab = vm.openQueryTab(connectionId: connectionId)
        vm.setEditorText("", for: tab.id)

        await vm.runActive()

        XCTAssertTrue(driver.executedSQLs.isEmpty)
        guard case .idle = vm.activeTab?.result else {
            return XCTFail("expected result untouched (.idle), got \(String(describing: vm.activeTab?.result))")
        }
    }

    func testRunWhitespaceOnlyTextIsNoOp() async throws {
        let (vm, driver, _) = makeFixture()
        let tab = vm.openQueryTab(connectionId: connectionId)
        vm.setEditorText("   \n\t  ", for: tab.id)

        await vm.runActive()

        XCTAssertTrue(driver.executedSQLs.isEmpty)
        guard case .idle = vm.activeTab?.result else {
            return XCTFail("expected result untouched (.idle)")
        }
    }

    func testRunErrorSurfacesMessageInResult() async throws {
        let (vm, driver, _) = makeFixture(executeResult: .failure(FakeQueryError.queryFailed("boom")))
        let tab = vm.openQueryTab(connectionId: connectionId)
        vm.setEditorText("SELECT nope;", for: tab.id)

        await vm.runActive()

        XCTAssertTrue(driver.executedSQLs.contains("SELECT nope;"))
        guard case .error(let message) = vm.activeTab?.result else {
            return XCTFail("expected error result, got \(String(describing: vm.activeTab?.result))")
        }
        XCTAssertTrue(message.contains("boom"), "error message should contain 'boom', got \(message)")
    }

    func testRunWithoutConnectedDriverSetsErrorAndSkipsExecute() async throws {
        let (vm, driver, provider) = makeFixture()
        provider.install(driver, for: connectionId, connected: false)
        let tab = vm.openQueryTab(connectionId: connectionId)
        vm.setEditorText("SELECT 1;", for: tab.id)

        await vm.runActive()

        XCTAssertTrue(driver.executedSQLs.isEmpty)
        guard case .error = vm.activeTab?.result else {
            return XCTFail("expected not-connected error result")
        }
    }

    func testRunWithNoDriverAtAllSetsError() async throws {
        let provider = FakeDriverProvider()
        let vm = WorkspaceViewModel(drivers: provider)
        let tab = vm.openQueryTab(connectionId: connectionId)
        vm.setEditorText("SELECT 1;", for: tab.id)

        await vm.runActive()

        guard case .error = vm.activeTab?.result else {
            return XCTFail("expected not-connected error result")
        }
    }

    // MARK: - Browse loading

    private func makeBrowsePage(rows: [[SQLValue]], estimate: Int64? = nil) -> RowPage {
        RowPage(
            columns: [
                ColumnInfo(name: "id", dataType: "int4"),
                ColumnInfo(name: "email", dataType: "text"),
            ],
            rows: rows,
            totalCountEstimate: estimate
        )
    }

    func testLoadCurrentPageRequestsOffsetZeroLimitPageSizeAndMapsResult() async throws {
        let page = makeBrowsePage(rows: [[.int(1), .string("a@x.io")]], estimate: 42)
        let (vm, driver, _) = makeFixture(browseResult: .success(page))
        let tabId = openBrowseTab(vm)

        await vm.loadCurrentPage()

        XCTAssertEqual(driver.browseCalls.count, 1)
        let call = try XCTUnwrap(driver.browseCalls.first)
        XCTAssertEqual(call.table, TableRef(database: "shop", name: "users"))
        XCTAssertNil(call.sort)
        XCTAssertEqual(call.limit, 200)
        XCTAssertEqual(call.offset, 0)

        guard case .loaded(let result)? = vm.activeTab?.result else {
            return XCTFail("expected loaded browse result, got \(String(describing: vm.activeTab?.result))")
        }
        XCTAssertEqual(result.statementType, .select)
        XCTAssertEqual(result.columns.map(\.name), ["id", "email"])
        XCTAssertEqual(result.rows, [[.int(1), .string("a@x.io")]])
        XCTAssertEqual(vm.activeTab?.browse?.totalEstimate, 42)
        XCTAssertEqual(vm.activeTab?.id, tabId)
    }

    func testNextPageAdvancesOffsetUntilEstimateBoundaryThenStops() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, driver, _) = makeFixture(browseResult: .success(page))
        openBrowseTab(vm, estimate: 450)

        await vm.loadCurrentPage()
        await vm.nextPage()
        await vm.nextPage()
        await vm.nextPage() // would exceed 450 → ignored

        let offsets = driver.browseCalls.map(\.offset)
        XCTAssertEqual(offsets, [0, 200, 400], "nextPage must stop at the last partial page for a known total")
        XCTAssertEqual(vm.activeTab?.browse?.pageIndex, 2)
    }

    func testNextPageAdvancesFreelyWithoutEstimate() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, driver, _) = makeFixture(browseResult: .success(page))
        openBrowseTab(vm)

        await vm.loadCurrentPage()
        await vm.nextPage()
        await vm.nextPage()

        let offsets = driver.browseCalls.map(\.offset)
        XCTAssertEqual(offsets, [0, 200, 400])
    }

    func testPrevPageStepsBackAndFloorsAtZero() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, driver, _) = makeFixture(browseResult: .success(page))
        openBrowseTab(vm)

        await vm.loadCurrentPage()   // offset 0
        await vm.prevPage()          // already at floor → no-op, no extra call
        await vm.nextPage()          // offset 200
        await vm.nextPage()          // offset 400
        await vm.prevPage()          // offset 200

        let offsets = driver.browseCalls.map(\.offset)
        XCTAssertEqual(offsets, [0, 200, 400, 200])
        XCTAssertEqual(vm.activeTab?.browse?.pageIndex, 1)
    }

    func testNegativePageIndexClampsToZeroOnLoad() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, driver, _) = makeFixture(browseResult: .success(page))
        openBrowseTab(vm)
        let tabId = try XCTUnwrap(vm.activeTab?.id)
        vm.setPageIndex(-3, for: tabId)

        await vm.loadCurrentPage()

        let offsets = driver.browseCalls.map(\.offset)
        XCTAssertEqual(offsets, [0])
        XCTAssertEqual(vm.activeTab?.browse?.pageIndex, 0)
    }

    func testSetSortTogglesDirectionAndResetsToPageZero() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, driver, _) = makeFixture(browseResult: .success(page))
        openBrowseTab(vm)

        await vm.loadCurrentPage()          // nil sort, offset 0
        await vm.nextPage()                 // offset 200
        await vm.setSort(columnName: "id")  // new column → asc, back to page 0
        await vm.setSort(columnName: "id")  // same column → desc
        await vm.setSort(columnName: "email") // different column → asc

        let calls = driver.browseCalls
        XCTAssertEqual(calls.count, 5)
        XCTAssertNil(calls[0].sort); XCTAssertEqual(calls[0].offset, 0)
        XCTAssertNil(calls[1].sort); XCTAssertEqual(calls[1].offset, 200)
        XCTAssertEqual(calls[2].sort, SortSpec(columnName: "id", ascending: true))
        XCTAssertEqual(calls[2].offset, 0)
        XCTAssertEqual(calls[3].sort, SortSpec(columnName: "id", ascending: false))
        XCTAssertEqual(calls[3].offset, 0)
        XCTAssertEqual(calls[4].sort, SortSpec(columnName: "email", ascending: true))
        XCTAssertEqual(calls[4].offset, 0)
    }

    func testBrowseErrorSurfacesInResult() async throws {
        let (vm, _, _) = makeFixture(browseResult: .failure(FakeQueryError.queryFailed("browse blew up")))
        openBrowseTab(vm)

        await vm.loadCurrentPage()

        guard case .error(let message) = vm.activeTab?.result else {
            return XCTFail("expected browse error result")
        }
        XCTAssertTrue(message.contains("browse blew up"))
    }

    // MARK: - Staged-edit invalidation on snapshot change (Batch 6 review I1)

    func testBrowseSnapshotChangeHookFiresOnNavigationAndSort() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, _, _) = makeFixture(browseResult: .success(page))
        let tabId = openBrowseTab(vm)

        var invalidated: [UUID] = []
        vm.onBrowseSnapshotChange = { invalidated.append($0) }

        await vm.loadCurrentPage()
        XCTAssertTrue(invalidated.isEmpty, "the initial load is not a navigation")

        await vm.nextPage()
        XCTAssertEqual(invalidated, [tabId])

        await vm.prevPage()
        XCTAssertEqual(invalidated, [tabId, tabId])

        await vm.setSort(columnName: "id")
        XCTAssertEqual(invalidated, [tabId, tabId, tabId])
    }

    func testBrowseSnapshotChangeHookStaysSilentOnNoOpNavigation() async throws {
        let page = makeBrowsePage(rows: [])
        let (vm, _, _) = makeFixture(browseResult: .success(page))
        openBrowseTab(vm, estimate: 100) // single partial page

        var fired = 0
        vm.onBrowseSnapshotChange = { _ in fired += 1 }

        await vm.loadCurrentPage()
        await vm.nextPage() // would exceed the estimate → ignored
        await vm.prevPage() // already at the floor → no-op

        XCTAssertEqual(fired, 0)
    }

    // MARK: - Tab lifecycle

    /// Regression guard for connection switching: WorkspaceView recreates its
    /// whole view model per connection (`.id(connection.id)`), so each fresh
    /// bootstrap must bind tabs strictly to the connection it was created for.
    func testFreshViewModelBootstrapsTabsBoundToRespectiveConnectionIds() {
        let provider = FakeDriverProvider()
        let firstVM = WorkspaceViewModel(drivers: provider)
        let secondVM = WorkspaceViewModel(drivers: provider)
        let otherConnectionId = UUID()

        let firstTab = firstVM.openQueryTab(connectionId: connectionId)
        let secondTab = secondVM.openQueryTab(connectionId: otherConnectionId)

        XCTAssertEqual(firstVM.tabs.map(\.connectionId), [connectionId])
        XCTAssertEqual(secondVM.tabs.map(\.connectionId), [otherConnectionId])
        XCTAssertEqual(firstVM.activeTab?.id, firstTab.id)
        XCTAssertEqual(secondVM.activeTab?.id, secondTab.id)
    }

    func testOpenQueryTabReusesExistingFreeTabPerConnection() {
        let provider = FakeDriverProvider()
        let vm = WorkspaceViewModel(drivers: provider)

        let first = vm.openQueryTab(connectionId: connectionId)
        let second = vm.openQueryTab(connectionId: connectionId)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(vm.tabs.count, 1)
        XCTAssertEqual(vm.activeTabId, first.id)
        XCTAssertEqual(first.title, "Query 1")
    }

    func testForceNewQueryTabIncrementsTitlePerConnection() {
        let provider = FakeDriverProvider()
        let vm = WorkspaceViewModel(drivers: provider)

        let first = vm.openQueryTab(connectionId: connectionId)
        let second = vm.openQueryTab(connectionId: connectionId, forceNew: true)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.title, "Query 1")
        XCTAssertEqual(second.title, "Query 2")
        XCTAssertEqual(vm.tabs.count, 2)
        XCTAssertEqual(vm.activeTabId, second.id)

        // A separate connection starts its own counter at 1.
        let otherConnection = UUID()
        let other = vm.openQueryTab(connectionId: otherConnection)
        XCTAssertEqual(other.title, "Query 1")
    }

    func testOpenBrowseTableReusesTabPerRefWithinConnection() {
        let provider = FakeDriverProvider()
        let vm = WorkspaceViewModel(drivers: provider)
        let users = TableRef(database: "shop", schema: "public", name: "users")
        let orders = TableRef(database: "shop", name: "orders")

        let first = vm.openBrowseTable(users, connectionId: connectionId)
        let reused = vm.openBrowseTable(users, connectionId: connectionId)
        let other = vm.openBrowseTable(orders, connectionId: connectionId)

        XCTAssertEqual(first.id, reused.id)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertEqual(first.title, "shop.users")
        XCTAssertEqual(other.title, "shop.orders")
        XCTAssertEqual(first.browse?.ref, users)
        XCTAssertTrue(first.isBrowseMode)
        XCTAssertNil(first.browse?.sort)
        XCTAssertEqual(first.browse?.pageSize, 200)
        XCTAssertEqual(first.currentOffset, 0)
        XCTAssertEqual(vm.activeTabId, other.id)
    }

    func testCloseTabRemovesItAndActivatesNeighbor() {
        let provider = FakeDriverProvider()
        let vm = WorkspaceViewModel(drivers: provider)
        let t1 = vm.openQueryTab(connectionId: connectionId)
        let t2 = vm.openQueryTab(connectionId: connectionId, forceNew: true)
        let t3 = vm.openQueryTab(connectionId: connectionId, forceNew: true)

        vm.closeTab(id: t1.id) // closing non-active leaves active alone
        XCTAssertEqual(vm.tabs.map(\.id), [t2.id, t3.id])
        XCTAssertEqual(vm.activeTabId, t3.id)

        vm.closeTab(id: t3.id) // closing active last → falls back to previous
        XCTAssertEqual(vm.tabs.map(\.id), [t2.id])
        XCTAssertEqual(vm.activeTabId, t2.id)

        vm.closeTab(id: t2.id)
        XCTAssertTrue(vm.tabs.isEmpty)
        XCTAssertNil(vm.activeTabId)
    }

    func testCloseUnknownTabIsNoOp() {
        let provider = FakeDriverProvider()
        let vm = WorkspaceViewModel(drivers: provider)
        let tab = vm.openQueryTab(connectionId: connectionId)

        vm.closeTab(id: UUID())

        XCTAssertEqual(vm.tabs.map(\.id), [tab.id])
        XCTAssertEqual(vm.activeTabId, tab.id)
    }
}
