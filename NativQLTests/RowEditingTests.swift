import XCTest
import NativQLKit
@testable import NativQL

/// Driver double for row-editing tests: records every executeMutation call,
/// serves a configurable primary key, and can fail mutations on demand.
final class EditingDriver: DatabaseDriver, @unchecked Sendable {
    let kind = DatabaseKind.postgres

    var primaryKeys: Result<[String]?, Error> = .success(["id"])
    var affectedRows: Int64 = 1
    var mutationError: Error?

    private(set) var primaryKeyCalls: [TableRef] = []
    private(set) var mutations: [MutationStatement] = []

    func primaryKey(of table: TableRef) async throws -> [String]? {
        primaryKeyCalls.append(table)
        return try primaryKeys.get()
    }

    func executeMutation(_ statement: MutationStatement) async throws -> Int64 {
        if let mutationError { throw mutationError }
        mutations.append(statement)
        return affectedRows
    }

    func isConnected() async -> Bool { true }

    // Untouched by editing logic.
    func connect(_ config: ConnectionConfig) async throws { fatalError("unused") }
    func disconnect() async { fatalError("unused") }
    func cancelRunningQuery() async {}
    func execute(_ sql: String) async throws -> QueryResult { fatalError("unused") }
    func listDatabases() async throws -> [DatabaseInfo] { fatalError("unused") }
    func listTables(database: String, schema: String?) async throws -> [TableInfo] { fatalError("unused") }
    func listColumns(_ table: TableRef) async throws -> [ColumnInfo] { fatalError("unused") }
    func tableDDL(_ table: TableRef) async throws -> String { fatalError("unused") }
    func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode { fatalError("unused") }
    func createDatabase(named: String) async throws { fatalError("unused") }
    func dropDatabase(named: String) async throws { fatalError("unused") }
    func browseRows(_ table: TableRef, sort: SortSpec?, limit: Int, offset: Int) async throws -> RowPage {
        fatalError("unused")
    }
}

@MainActor
final class RowEditingTests: XCTestCase {
    private let ref = TableRef(database: "shop", name: "users")
    private lazy var tab = QueryTab(
        title: "shop.users",
        connectionId: UUID(),
        browse: BrowseState(ref: ref)
    )

    private let columns = [
        ColumnInfo(name: "id", dataType: "int4", isNullable: false, isPrimaryKey: true),
        ColumnInfo(name: "email", dataType: "text"),
        ColumnInfo(name: "age", dataType: "int4"),
    ]
    private let pkInfos = [ColumnInfo(name: "id", dataType: "int4", isNullable: false, isPrimaryKey: true)]

    private func makeService() -> RowOperationsService { RowOperationsService() }

    // MARK: - Editability resolution

    func testResolveEditabilityCachesPrimaryKeyPerTableRef() async {
        let driver = EditingDriver()
        let service = makeService()

        let first = await service.resolveEditability(for: tab, driver: driver)
        let second = await service.resolveEditability(for: tab, driver: driver)

        XCTAssertEqual(first, .editable)
        XCTAssertEqual(second, .editable)
        XCTAssertEqual(driver.primaryKeyCalls.count, 1, "second resolution must hit the per-table cache")
    }

    func testResolveEditabilityWithoutPKReturnsKitReasonVerbatim() async {
        let driver = EditingDriver()
        driver.primaryKeys = .success([])
        let service = makeService()

        let decision = await service.resolveEditability(for: tab, driver: driver)

        XCTAssertEqual(
            decision,
            .readOnly(reason: "Table has no primary key, so rows can't be updated safely.")
        )
    }

    func testResolveEditabilityWhenLookupFailsFallsBackToReadOnly() async {
        let driver = EditingDriver()
        driver.primaryKeys = .failure(FakeQueryError.queryFailed("introspection down"))
        let service = makeService()

        let decision = await service.resolveEditability(for: tab, driver: driver)

        XCTAssertEqual(
            decision,
            .readOnly(reason: "Table has no primary key, so rows can't be updated safely.")
        )
    }

    // MARK: - Staging cell edits

    func testStageCellEditRejectsIdenticalValue() {
        let service = makeService()

        let staged = service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("a@x.io"),
            pkValues: ["id": .int(1)]
        )

        XCTAssertFalse(staged)
        XCTAssertEqual(service.dirtyCount(for: tab.id), 0)
    }

    func testStageCellEditUpsertsSameCellKeepingFirstOriginal() throws {
        let service = makeService()
        let pk = ["id": SQLValue.int(1)]
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: pk
        )
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("b@x.io"), newValue: .string("c@x.io"), pkValues: pk
        )

        let staged = try XCTUnwrap(service.stagedEdits(for: tab.id))
        XCTAssertEqual(staged.changes.count, 1)
        guard case .cell(let edit) = staged.changes[0] else {
            return XCTFail("expected a cell edit")
        }
        XCTAssertEqual(edit.original, .string("a@x.io"), "original must stay the database value")
        XCTAssertEqual(edit.newValue, .string("c@x.io"))
    }

    func testStageCellEditOnDeletedRowIsRejected() {
        let service = makeService()
        service.stageRowDelete(tabId: tab.id, rowIndex: 1, pkValues: [.int(2)], displayPreview: "id=2")

        let staged = service.stageCellEdit(
            tabId: tab.id, rowIndex: 1, columnName: "email",
            original: .null, newValue: .string("x"), pkValues: ["id": .int(2)]
        )

        XCTAssertFalse(staged, "editing a row queued for deletion must be rejected")
        XCTAssertEqual(service.stagedEdits(for: tab.id)?.changes.count, 1)
    }

    func testNullAndEmptyStringTransitionsStageDistinctly() {
        let service = makeService()
        let pk = ["id": SQLValue.int(1)]

        XCTAssertTrue(service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .null, pkValues: pk
        ))
        XCTAssertTrue(service.stageCellEdit(
            tabId: tab.id, rowIndex: 1, columnName: "email",
            original: .string("b@x.io"), newValue: .string(""), pkValues: pk
        ))

        let changes = service.stagedEdits(for: tab.id)?.changes ?? []
        XCTAssertEqual(changes.count, 2, "NULL and empty-string edits are distinct staged changes")
        guard case .cell(let toNull) = changes[0], case .cell(let toEmpty) = changes[1] else {
            return XCTFail("expected two cell edits")
        }
        XCTAssertEqual(toNull.newValue, .null)
        XCTAssertEqual(toEmpty.newValue, .string(""))
        XCTAssertNotEqual(toNull.newValue, toEmpty.newValue)
    }

    // MARK: - Insert placeholders

    func testInsertPlaceholderMapsSimpleDefaultsElseNull() {
        let service = makeService()
        let defaulted = [
            ColumnInfo(name: "id", dataType: "int4", defaultValue: "42"),
            ColumnInfo(name: "name", dataType: "text", defaultValue: "'ada'"),
            ColumnInfo(name: "created", dataType: "timestamptz", defaultValue: "now()"),
            ColumnInfo(name: "notes", dataType: "text"),
        ]

        let row = service.stageRowInsert(tabId: tab.id, columns: defaulted)

        XCTAssertEqual(row, [.int(42), .string("ada"), .null, .null])
        XCTAssertEqual(service.pendingInserts(for: tab.id).count, 1)
    }

    // MARK: - Reverts

    func testRevertCellRemovesOnlyThatEditAndRevertAllClearsTab() {
        let service = makeService()
        let pk = ["id": SQLValue.int(1)]
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: pk
        )
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "age",
            original: .int(30), newValue: .int(31), pkValues: pk
        )

        service.revertCell(tabId: tab.id, rowIndex: 0, columnName: "email")

        XCTAssertEqual(service.stagedEdits(for: tab.id)?.changes.count, 1)

        service.revertAll(tabId: tab.id)
        XCTAssertEqual(service.dirtyCount(for: tab.id), 0)
    }

    // MARK: - Commit pipeline

    func testCommitRunsUpdatesThenInsertsThenDeletesInOrder() async throws {
        let driver = EditingDriver()
        let service = makeService()
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("edited@x.io"),
            pkValues: ["id": .int(1)]
        )
        service.stageRowDelete(tabId: tab.id, rowIndex: 1, pkValues: [.int(2)], displayPreview: "id=2")
        service.stageRowInsert(tabId: tab.id, columns: columns)
        service.stageInsertedCell(tabId: tab.id, insertIndex: 0, columnIndex: 1, newValue: .string("new@x.io"))

        try await service.commit(tab: tab, driver: driver)

        XCTAssertEqual(driver.mutations.map(\.kind), [.update, .insert, .delete])

        let update = driver.mutations[0]
        XCTAssertEqual(update.sql, "UPDATE \"users\" SET \"email\" = ? WHERE \"id\" = ?")
        XCTAssertEqual(update.batches, [[.string("edited@x.io"), .int(1)]])

        let insert = driver.mutations[1]
        XCTAssertEqual(insert.sql, "INSERT INTO \"users\" (\"id\", \"email\", \"age\") VALUES (?, ?, ?);")
        XCTAssertEqual(insert.batches, [[.null, .string("new@x.io"), .null]])

        let delete = driver.mutations[2]
        XCTAssertEqual(delete.sql, "DELETE FROM \"users\" WHERE \"id\" = ?")
        XCTAssertEqual(delete.batches, [[.int(2)]])
    }

    func testCommitGroupsMultipleCellEditsOfSameRowIntoOneUpdate() async throws {
        let driver = EditingDriver()
        let service = makeService()
        let pk = ["id": SQLValue.int(1)]
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: pk
        )
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "age",
            original: .int(30), newValue: .int(31), pkValues: pk
        )

        try await service.commit(tab: tab, driver: driver)

        XCTAssertEqual(driver.mutations.count, 1)
        XCTAssertEqual(driver.mutations[0].sql, "UPDATE \"users\" SET \"email\" = ?, \"age\" = ? WHERE \"id\" = ?")
        XCTAssertEqual(driver.mutations[0].batches, [[.string("b@x.io"), .int(31), .int(1)]])
    }

    func testCommitClearsStagingOnSuccess() async {
        let driver = EditingDriver()
        let service = makeService()
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: ["id": .int(1)]
        )

        try? await service.commit(tab: tab, driver: driver)

        XCTAssertEqual(service.dirtyCount(for: tab.id), 0)
    }

    func testCommitFailurePreservesStagingAndRethrows() async {
        let driver = EditingDriver()
        driver.mutationError = FakeQueryError.queryFailed("constraint violated")
        let service = makeService()
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: ["id": .int(1)]
        )

        do {
            try await service.commit(tab: tab, driver: driver)
            XCTFail("expected commit to rethrow the driver error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "constraint violated")
        }
        XCTAssertEqual(service.dirtyCount(for: tab.id), 1, "staging must survive a failed commit")
        XCTAssertTrue(driver.mutations.isEmpty, "failed statement must not be recorded as applied")
    }

    func testCommitWithNothingStagedIsNoOp() async {
        let driver = EditingDriver()
        let service = makeService()

        try? await service.commit(tab: tab, driver: driver)

        XCTAssertTrue(driver.mutations.isEmpty)
        XCTAssertTrue(driver.primaryKeyCalls.isEmpty, "no-op commit must not introspect")
    }

    // MARK: - Affected-rows insurance (Batch 6 review I2)

    func testCommitAbortsWhenUpdateAffectsZeroRows() async {
        let driver = EditingDriver()
        driver.affectedRows = 0
        let service = makeService()
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"),
            pkValues: ["id": .int(1)]
        )

        do {
            try await service.commit(tab: tab, driver: driver)
            XCTFail("a zero-row UPDATE must abort the commit")
        } catch let error as DriverError {
            guard case .mutationFailed(let message) = error else {
                return XCTFail("expected mutationFailed, got \(error)")
            }
            XCTAssertEqual(message, "Row changed or no longer matches — refresh and retry")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(driver.mutations.map(\.kind), [.update],
                       "the failing statement ran; nothing further may run")
        XCTAssertEqual(service.dirtyCount(for: tab.id), 1,
                       "staging must survive the aborted commit")
    }

    func testCommitAbortsWhenDeleteAffectsZeroRows() async {
        let driver = EditingDriver()
        driver.affectedRows = 0
        let service = makeService()
        service.stageRowDelete(tabId: tab.id, rowIndex: 0, pkValues: [.int(1)], displayPreview: "id=1")

        do {
            try await service.commit(tab: tab, driver: driver)
            XCTFail("a zero-row DELETE must abort the commit")
        } catch let error as DriverError {
            guard case .mutationFailed(let message) = error else {
                return XCTFail("expected mutationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("refresh"), message)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(service.dirtyCount(for: tab.id), 1)
    }

    func testCommitExemptsInsertsFromAffectedRowsInsurance() async {
        let driver = EditingDriver()
        driver.affectedRows = 0
        let service = makeService()
        service.stageRowInsert(tabId: tab.id, columns: columns)
        service.stageInsertedCell(tabId: tab.id, insertIndex: 0, columnIndex: 1, newValue: .string("new@x.io"))

        try? await service.commit(tab: tab, driver: driver)

        XCTAssertEqual(driver.mutations.map(\.kind), [.insert])
        XCTAssertEqual(service.dirtyCount(for: tab.id), 0,
                       "inserts commit normally regardless of the affected count")
    }

    // MARK: - Snapshot invalidation wiring (Batch 6 review I1)

    /// rowIndex-keyed staging is only valid within ONE rendered page snapshot;
    /// navigating pages or re-sorting must discard ALL staged edits for the
    /// tab via the workspace's snapshot-change hook.
    func testNavigationClearsAllStagedEditsForTheTab() async {
        let service = makeService()
        let provider = FakeDriverProvider()
        let navigationConnectionId = UUID()
        provider.install(FakeDriver(), for: navigationConnectionId)
        let vm = WorkspaceViewModel(drivers: provider)
        let browseTab = vm.openBrowseTable(
            TableRef(database: "shop", name: "users"),
            connectionId: navigationConnectionId
        )
        vm.onBrowseSnapshotChange = { service.revertAll(tabId: $0) }

        service.stageCellEdit(
            tabId: browseTab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"),
            pkValues: ["id": .int(1)]
        )
        service.stageRowDelete(tabId: browseTab.id, rowIndex: 1, pkValues: [.int(2)], displayPreview: "id=2")
        XCTAssertGreaterThan(service.dirtyCount(for: browseTab.id), 0)

        await vm.nextPage()

        XCTAssertEqual(service.dirtyCount(for: browseTab.id), 0,
                       "a page change must invalidate every staged edit for the tab")
    }

    func testSortChangeClearsAllStagedEditsForTheTab() async {
        let service = makeService()
        let provider = FakeDriverProvider()
        let sortConnectionId = UUID()
        provider.install(FakeDriver(), for: sortConnectionId)
        let vm = WorkspaceViewModel(drivers: provider)
        let browseTab = vm.openBrowseTable(
            TableRef(database: "shop", name: "users"),
            connectionId: sortConnectionId
        )
        vm.onBrowseSnapshotChange = { service.revertAll(tabId: $0) }

        service.stageCellEdit(
            tabId: browseTab.id, rowIndex: 3, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"),
            pkValues: ["id": .int(4)]
        )
        await vm.setSort(columnName: "email")

        XCTAssertEqual(service.dirtyCount(for: browseTab.id), 0,
                       "a re-sort reorders rows, so rowIndex keys go stale")
    }

    // MARK: - BrowseEditorViewModel

    func testEditorExposesEditableStateAndKitReasonVerbatim() async {
        let driver = EditingDriver()
        driver.primaryKeys = .success([])
        let service = makeService()
        let editor = BrowseEditorViewModel(
            service: service,
            tabProvider: { [tab] in tab },
            driverResolver: { driver }
        )

        await editor.refreshDecision()

        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.reasonText, "Table has no primary key, so rows can't be updated safely.")
    }

    func testEditorCommitSignalsSuccessAndClearsDirty() async {
        let driver = EditingDriver()
        let service = makeService()
        let editor = BrowseEditorViewModel(
            service: service,
            tabProvider: { [tab] in tab },
            driverResolver: { driver }
        )
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: ["id": .int(1)]
        )
        var successes = 0
        editor.onCommitSuccess = { successes += 1 }

        await editor.commit()

        XCTAssertEqual(successes, 1)
        XCTAssertNil(editor.lastCommitError)
        XCTAssertEqual(editor.dirtyCount, 0)
    }

    func testEditorFailedCommitSurfacesErrorAndKeepsDirtyCount() async {
        let driver = EditingDriver()
        driver.mutationError = FakeQueryError.queryFailed("deadlock")
        let service = makeService()
        let editor = BrowseEditorViewModel(
            service: service,
            tabProvider: { [tab] in tab },
            driverResolver: { driver }
        )
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .string("b@x.io"), pkValues: ["id": .int(1)]
        )
        var successes = 0
        editor.onCommitSuccess = { successes += 1 }

        await editor.commit()

        XCTAssertEqual(successes, 0)
        XCTAssertEqual(editor.lastCommitError, "deadlock")
        XCTAssertEqual(editor.dirtyCount, 1)
        XCTAssertEqual(editor.stagedSummary, "1 edited")
    }

    // MARK: - Grid wiring helpers

    func testEditorPkBindingsExtractsPrimaryKeyValuesForRowAfterResolution() async {
        let driver = EditingDriver()
        let service = makeService()
        let editor = BrowseEditorViewModel(
            service: service,
            tabProvider: { [tab] in tab },
            driverResolver: { driver }
        )
        await editor.refreshDecision()

        let bindings = editor.pkBindings(
            rowIndex: 0,
            rows: [[.int(1), .string("a@x.io"), .int(30)], [.int(2), .null, .int(40)]],
            columns: columns
        )

        XCTAssertEqual(bindings, ["id": .int(1)])
        XCTAssertTrue(editor.pkBindings(
            rowIndex: 9,
            rows: [[.int(1)]],
            columns: columns
        ).isEmpty, "out-of-range rows (pending inserts) carry no pk bindings")
    }

    func testEditorStagedCellMapKeysStagedValuesByRowAndColumn() throws {
        let service = makeService()
        let editor = BrowseEditorViewModel(
            service: service,
            tabProvider: { [tab] in tab },
            driverResolver: { EditingDriver() }
        )
        service.stageCellEdit(
            tabId: tab.id, rowIndex: 0, columnName: "email",
            original: .string("a@x.io"), newValue: .null, pkValues: ["id": .int(1)]
        )

        let map = editor.stagedCellMap(columns: columns)

        XCTAssertEqual(map, [StagedCellRef(row: 0, column: 1): SQLValue.null])
    }
}
