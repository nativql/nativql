import XCTest
import SwiftData
import NativQLKit
@testable import NativQL

/// Batch 7: history recording, saved queries, export services, and the small
/// pure helpers behind explain gating + settings clamping.
@MainActor
final class PolishTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try NativQLModelContainer.inMemory()
    }

    private func makeContext() -> ModelContext {
        ModelContext(container)
    }

    // MARK: - Container round-trips

    func testInMemoryContainerRoundTripsHistoryEntriesAcrossContexts() throws {
        let writer = makeContext()
        let entry = QueryHistoryEntry(
            sql: "SELECT 1;", connectionName: "local", kind: "query",
            executedAt: Date(timeIntervalSince1970: 100), durationMs: 3.5, ok: true
        )
        writer.insert(entry)
        try writer.save()

        let reader = makeContext()
        let fetched = try reader.fetch(FetchDescriptor<QueryHistoryEntry>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.sql, "SELECT 1;")
        XCTAssertEqual(fetched.first?.connectionName, "local")
        XCTAssertEqual(fetched.first?.kind, "query")
        XCTAssertEqual(fetched.first?.durationMs, 3.5)
        XCTAssertEqual(fetched.first?.ok, true)
    }

    func testInMemoryContainerRoundTripsSavedQueriesAndFolders() throws {
        let writer = makeContext()
        let query = SavedQuery(name: "Active users", sql: "SELECT * FROM users;", folderPath: "Reports/Q3")
        let folder = SavedFolder(name: "Q3", parentPath: "Reports")
        writer.insert(query)
        writer.insert(folder)
        try writer.save()

        let reader = makeContext()
        XCTAssertEqual(try reader.fetch(FetchDescriptor<SavedQuery>()).count, 1)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<SavedFolder>()).count, 1)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<SavedQuery>()).first?.folderPath, "Reports/Q3")
        XCTAssertEqual(try reader.fetch(FetchDescriptor<SavedFolder>()).first?.fullPath, "Reports/Q3")
    }

    func testSharedSchemaCoversAllThreeModels() {
        let names = Set(NativQLModelContainer.schema.entities.compactMap(\.name))
        XCTAssertTrue(names.contains("QueryHistoryEntry"))
        XCTAssertTrue(names.contains("SavedQuery"))
        XCTAssertTrue(names.contains("SavedFolder"))
    }

    // MARK: - HistoryRecorder

    func testRecorderSkipsWhitespaceOnlySQL() throws {
        let context = makeContext()
        let recorder = HistoryRecorder(context: context)

        recorder.record(sql: "   \n\t ", connectionName: "local", kind: .query, ok: true, durationMs: 1)
        recorder.record(sql: "", connectionName: "local", kind: .query, ok: false, durationMs: 1)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueryHistoryEntry>()), 0)
    }

    func testRecorderRecordsOkFailKindAndDuration() throws {
        let context = makeContext()
        let recorder = HistoryRecorder(context: context)

        recorder.record(sql: "SELECT 1;", connectionName: "prod", kind: .query, ok: true, durationMs: 12.25)
        recorder.record(sql: "DELETE FROM nope;", connectionName: "prod", kind: .query, ok: false, durationMs: 40)

        let entries = try context.fetch(FetchDescriptor<QueryHistoryEntry>())
        XCTAssertEqual(entries.count, 2)
        let okEntry = entries.first { $0.ok }
        let failEntry = entries.first { !$0.ok }
        XCTAssertEqual(okEntry?.sql, "SELECT 1;")
        XCTAssertEqual(okEntry?.durationMs ?? -1, 12.25, accuracy: 0.001)
        XCTAssertEqual(failEntry?.sql, "DELETE FROM nope;")
        XCTAssertEqual(failEntry?.kind, "query")
    }

    func testRecorderCapsAtFiveHundredDeletingOldestFirst() throws {
        let context = makeContext()
        let recorder = HistoryRecorder(context: context)
        let base = Date(timeIntervalSince1970: 0)

        for i in 0..<505 {
            recorder.record(
                sql: "SELECT \(i);", connectionName: "local", kind: .query,
                executedAt: base.addingTimeInterval(Double(i)), ok: true, durationMs: 1
            )
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueryHistoryEntry>()), 500)
        let remaining = try context.fetch(
            FetchDescriptor<QueryHistoryEntry>(sortBy: [SortDescriptor(\.executedAt)])
        )
        XCTAssertEqual(remaining.first?.sql, "SELECT 5;", "oldest five must be evicted first")
        XCTAssertEqual(remaining.last?.sql, "SELECT 504;")
    }

    func testRecorderTrimsDownWhenCalledAboveCapacity() throws {
        let context = makeContext()
        for i in 0..<520 {
            context.insert(QueryHistoryEntry(
                sql: "q\(i)", connectionName: "c", kind: "query",
                executedAt: Date(timeIntervalSince1970: Double(i)), durationMs: 0, ok: true
            ))
        }
        let recorder = HistoryRecorder(context: context)

        recorder.record(sql: "newest", connectionName: "c", kind: .query, ok: true, durationMs: 0)

        let count = try context.fetchCount(FetchDescriptor<QueryHistoryEntry>())
        XCTAssertLessThanOrEqual(count, HistoryRecorder.capacity)
        let newest = try context.fetch(
            FetchDescriptor<QueryHistoryEntry>(sortBy: [SortDescriptor(\.executedAt, order: .reverse)])
        ).first
        XCTAssertEqual(newest?.sql, "newest")
    }

    // MARK: - HistoryViewModel

    private func seedHistory(_ context: ModelContext) {
        context.insert(QueryHistoryEntry(
            sql: "SELECT * FROM orders;", connectionName: "prod", kind: "query",
            executedAt: Date(timeIntervalSince1970: 300), durationMs: 5, ok: true
        ))
        context.insert(QueryHistoryEntry(
            sql: "UPDATE users SET name = 'x';", connectionName: "staging", kind: "query",
            executedAt: Date(timeIntervalSince1970: 200), durationMs: 8, ok: false
        ))
        context.insert(QueryHistoryEntry(
            sql: "INSERT INTO logs VALUES (1);", connectionName: "prod", kind: "query",
            executedAt: Date(timeIntervalSince1970: 100), durationMs: 2, ok: true
        ))
    }

    func testHistoryViewModelListsEntriesNewestFirst() throws {
        let context = makeContext()
        seedHistory(context)
        let viewModel = HistoryViewModel(context: context)

        viewModel.refresh()

        XCTAssertEqual(viewModel.entries.map(\.connectionName), ["prod", "staging", "prod"])
        XCTAssertEqual(viewModel.entries.map { $0.executedAt.timeIntervalSince1970 }, [300, 200, 100])
    }

    func testHistoryViewModelSearchFiltersOnSQLAndConnectionNameCaseInsensitive() throws {
        let context = makeContext()
        seedHistory(context)
        let viewModel = HistoryViewModel(context: context)
        viewModel.refresh()

        viewModel.searchText = "ORDERS"
        XCTAssertEqual(viewModel.visibleEntries.count, 1)
        XCTAssertEqual(viewModel.visibleEntries.first?.sql, "SELECT * FROM orders;")

        viewModel.searchText = "stag"
        XCTAssertEqual(viewModel.visibleEntries.count, 1)
        XCTAssertEqual(viewModel.visibleEntries.first?.connectionName, "staging")

        viewModel.searchText = "zzz-no-match"
        XCTAssertTrue(viewModel.visibleEntries.isEmpty)
    }

    func testHistoryViewModelDeleteRemovesEntry() throws {
        let context = makeContext()
        seedHistory(context)
        let viewModel = HistoryViewModel(context: context)
        viewModel.refresh()
        let victim = try XCTUnwrap(viewModel.entries.first)

        viewModel.delete(victim)
        viewModel.refresh()

        XCTAssertEqual(viewModel.entries.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueryHistoryEntry>()), 2)
    }

    // MARK: - SavedQueriesViewModel

    func testSavedQueriesAddRenameUpdateSQLAndDelete() throws {
        let context = makeContext()
        let viewModel = SavedQueriesViewModel(context: context)

        viewModel.add(name: "Daily", sql: "SELECT 1;")
        viewModel.refresh()
        XCTAssertEqual(viewModel.queries.count, 1)
        XCTAssertNil(viewModel.queries.first?.folderPath)

        let query = try XCTUnwrap(viewModel.queries.first)
        viewModel.rename(query, to: "Daily revenue")
        viewModel.updateSQL(query, text: "SELECT total FROM revenue;")
        viewModel.refresh()
        XCTAssertEqual(viewModel.queries.first?.name, "Daily revenue")
        XCTAssertEqual(viewModel.queries.first?.sql, "SELECT total FROM revenue;")

        viewModel.delete(query)
        viewModel.refresh()
        XCTAssertTrue(viewModel.queries.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedQuery>()), 0)
    }

    func testSavedQueriesMoveToFolderAndGroupingByFolderPath() throws {
        let context = makeContext()
        let viewModel = SavedQueriesViewModel(context: context)
        viewModel.addFolder(named: "Reports", parentPath: nil)
        viewModel.addFolder(named: "Q3", parentPath: "Reports")

        viewModel.refresh()
        XCTAssertEqual(Set(viewModel.folders.map(\.fullPath)), ["Reports", "Reports/Q3"])

        viewModel.add(name: "Revenue", sql: "SELECT sum(x);", folderPath: nil)
        viewModel.refresh()
        let revenue = try XCTUnwrap(viewModel.queries.first)

        viewModel.move(revenue, to: "Reports/Q3")
        viewModel.refresh()

        XCTAssertEqual(revenue.folderPath, "Reports/Q3")
        XCTAssertEqual(viewModel.queries(inFolder: "Reports/Q3").map(\.name), ["Revenue"])
        XCTAssertEqual(viewModel.queries(inFolder: nil).count, 0)

        viewModel.move(revenue, to: nil)
        viewModel.refresh()
        XCTAssertNil(revenue.folderPath)
        XCTAssertEqual(viewModel.queries(inFolder: nil).map(\.name), ["Revenue"])
    }

    func testSavedQueriesQueriesSortedByNameAscending() throws {
        let context = makeContext()
        let viewModel = SavedQueriesViewModel(context: context)
        viewModel.add(name: "zebra", sql: "SELECT 1;")
        viewModel.add(name: "alpha", sql: "SELECT 2;")

        viewModel.refresh()

        XCTAssertEqual(viewModel.queries.map(\.name), ["alpha", "zebra"])
    }

    // MARK: - ExportService

    private var sampleColumns: [ColumnInfo] {
        [
            ColumnInfo(name: "id", dataType: "int4"),
            ColumnInfo(name: "name", dataType: "text"),
        ]
    }

    private var sampleRows: [[SQLValue]] {
        [[.int(1), .string("plain")], [.null, .string("has, comma")]]
    }

    func testExportServiceBuildCSVMatchesKitExporterOutput() {
        let service = ExportService()
        XCTAssertEqual(
            service.buildCSV(columns: sampleColumns, rows: sampleRows),
            CSVExporter.export(columns: sampleColumns, rows: sampleRows)
        )
        XCTAssertTrue(service.buildCSV(columns: sampleColumns, rows: sampleRows).contains("\"has, comma\""))
    }

    func testExportServiceBuildJSONMatchesKitExporterOutput() {
        let service = ExportService()
        XCTAssertEqual(
            service.buildJSON(columns: sampleColumns, rows: sampleRows),
            JSONExporter.export(columns: sampleColumns, rows: sampleRows)
        )
        XCTAssertTrue(service.buildJSON(columns: sampleColumns, rows: sampleRows).contains("\"id\" : 1"))
    }

    func testSuggestedFilenameSanitizesAndAppendsExtension() {
        let service = ExportService()
        XCTAssertEqual(service.suggestedFilename(tableOrQuery: "public.users", ext: "csv"), "public.users.csv")

        let weird = service.suggestedFilename(tableOrQuery: "we/ird:name*", ext: "json")
        XCTAssertFalse(weird.contains("/"))
        XCTAssertFalse(weird.contains(":"))
        XCTAssertTrue(weird.hasSuffix(".json"))
    }

    // MARK: - Explain gate

    func testExplainGateEnabledForSelectResultBrowseOrEditorText() async throws {
        let connectionId = UUID()
        let provider = FakeDriverProvider()
        let driver = FakeDriver()
        driver.executeResult = .success(QueryResult(
            columns: [ColumnInfo(name: "n", dataType: "int4")],
            rows: [[.int(1)]], executionMilliseconds: 0, statementType: .select
        ))
        provider.install(driver, for: connectionId)
        let vm = WorkspaceViewModel(drivers: provider)
        let tab = vm.openQueryTab(connectionId: connectionId)

        XCTAssertFalse(ExplainGate.canRun(activeTab: vm.activeTab), "empty editor → disabled")

        vm.setEditorText("UPDATE t SET x = 1;", for: tab.id)
        XCTAssertFalse(ExplainGate.canRun(activeTab: vm.activeTab))

        vm.setEditorText("with cte as (select 1) select * from cte", for: tab.id)
        XCTAssertTrue(ExplainGate.canRun(activeTab: vm.activeTab), "case-insensitive WITH prefix")

        vm.setEditorText("SELECT * FROM t;", for: tab.id)
        XCTAssertTrue(ExplainGate.canRun(activeTab: vm.activeTab))

        // A select-shaped RESULT enables explain even though the text is not.
        vm.setEditorText("UPDATE t SET x = 1;", for: tab.id)
        await vm.runActive()
        XCTAssertTrue(ExplainGate.canRun(activeTab: vm.activeTab), "select-shaped result enables explain")

        // Mutation-shaped result + non-SELECT text stays disabled.
        driver.executeResult = .success(QueryResult(
            columns: [], rows: [], executionMilliseconds: 0, statementType: .update
        ))
        await vm.runActive()
        XCTAssertFalse(ExplainGate.canRun(activeTab: vm.activeTab), "mutation result without select text stays disabled")

        XCTAssertFalse(ExplainGate.canRun(activeTab: nil))
    }

    func testExplainGateResolvesEditorSQLOverBrowseFallback() {
        let ref = TableRef(database: "shop", schema: "public", name: "users")
        var browseTab = QueryTab(title: "shop.users", connectionId: UUID(), browse: BrowseState(ref: ref))
        browseTab.result = .loaded(QueryResult(
            columns: [], rows: [], executionMilliseconds: 0, statementType: .select
        ))
        XCTAssertEqual(ExplainGate.explainableSQL(for: browseTab), "SELECT * FROM \"public\".\"users\"")

        var editorTab = QueryTab(title: "q", connectionId: browseTab.connectionId)
        editorTab.editorText = "  SELECT id FROM orders WHERE x > 1;"
        XCTAssertEqual(ExplainGate.explainableSQL(for: editorTab), "SELECT id FROM orders WHERE x > 1;")
    }

    // MARK: - Settings clamping

    func testSettingsStoreClampsFontAndRowLimitWithDefaults() throws {
        let suiteName = "polish-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.editorFontSize, 13, "default font size")
        XCTAssertEqual(store.defaultRowLimit, 200, "default row limit matches BrowseState default")

        store.editorFontSize = 99
        XCTAssertEqual(store.editorFontSize, 20)
        store.editorFontSize = 1
        XCTAssertEqual(store.editorFontSize, 11)

        store.defaultRowLimit = 10_000
        XCTAssertEqual(store.defaultRowLimit, 1000)
        store.defaultRowLimit = 5
        XCTAssertEqual(store.defaultRowLimit, 50)

        store.editorFontSize = 15
        store.defaultRowLimit = 250
        XCTAssertEqual(defaults.double(forKey: SettingsKey.editorFontSize), 15, "persisted to UserDefaults")
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.defaultRowLimit), 250)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.editorFontSize, 15, "reads back persisted values")
        XCTAssertEqual(reloaded.defaultRowLimit, 250)
    }
}
