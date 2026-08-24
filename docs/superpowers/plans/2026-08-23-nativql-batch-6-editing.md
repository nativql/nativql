# NativQL Batch 6 — Inline Editing & Row Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans.

**Goal:** TablePlus-style inline cell editing in browse mode — staged changes with dirty markers, ⌘S transactional commit, insert/delete rows, read-only enforcement with reasons.

**Architecture:** Kit's `EditabilityRules` + `MutationStatement`/`InsertStatementBuilder` already exist. New `RowOperationsService` (app layer, TDD-heavy): computes editability for a browse tab (driver PK lookup + source kind), stages cell edits/adds/deletes per tab, builds dialect statements via a NEW `UpdateStatementBuilder`+`DeleteStatementBuilder` (Kit additions mirroring InsertStatementBuilder), commits via driver.executeMutation inside one transaction. Grid gains edit mode: double-click editable cell → NSTextField overlay; Enter commits stage; Esc cancels; staged cells show dot badge + amber tint. NULL handling: explicit "Set NULL" via context menu on staged cell + empty-string distinct.

**Tech Stack:** existing stack; no new deps.

**Worktree:** `.worktrees/batch-6-editing`, branch off main.
**Working dir:** `/Users/sipamungkas/Documents/projects/macos/nativql/.worktrees/batch-6-editing`

---

## File Structure (locked)

```
Packages/NativQLKit/
├── Sources/NativQLKit/Utilities/UpdateStatementBuilder.swift   # UPDATE t SET c=? WHERE pk1=? AND pk2=?
├── Sources/NativQLKit/Utilities/DeleteStatementBuilder.swift   # DELETE FROM t WHERE pk IN ((..),(..)) per-row batches
└── Tests/NativQLKitTests/RowBuildersTests.swift
NativQL/
├── Services/RowOperationsService.swift     # @MainActor: editability resolution, staging store per tab, commit pipeline
├── State/StagedEdits.swift                 # models: CellEdit(rowIdx,colName,original,new), RowInsert(values), RowDelete(rowPKValues)
├── ViewModels/BrowseEditorViewModel.swift  # bridges grid ↔ service (stage/revert/commit), dirty counts
└── Views/Workspace/Results/
    ├── EditableCellView.swift              # double-click editor overlay
    └── ResultsGridView.swift               # MODIFY: editing hooks, dirty badges, insert row placeholder, delete menu
NativQLTests/
└── RowEditingTests.swift                   # service logic with FakeDriver
```

## Task A: Kit statement builders (TDD)

1. `UpdateStatementBuilder.build(table:pkColumns:[ColumnInfo], changes:[(columnName:String,newValue:SQLValue)], pkValues:[String:SQLValue]) -> MutationStatement`: `UPDATE "s"."t" SET "c" = ? WHERE "pk" = ? AND ...` single batch [new..., pk...]; kind .update.
2. `DeleteStatementBuilder.build(table:pkColumns:, rows:[[SQLValue]])` → sql `DELETE FROM t WHERE ("pk1","pk2") IN ((?,?),(?,?));`? Dialect risk: tuple-IN not portable to MySQL. Use per-row WHERE AND-chains with one batch PER ROW (matches executeMutation batches semantics): sql `DELETE FROM t WHERE pk=? AND pk2=?`, batches [[pk...] per row]. Same shape for multi-update? Update stays single-batch per row too: batches array of per-row bindings, sql without IN.
3. Tests: SQL strings exact, quoting doubling, batch binding order, empty inputs throw/nil-safe (decide: preconditionFailure vs return nil — choose returning nil optional and document).
4. Commit "feat(kit): UPDATE/DELETE statement builders".

## Task B: RowOperationsService + VM (TDD with FakeDriver)

1. `StagedEdits.swift`: structs per plan + enum StagedChange { cell(CellEdit), insert(RowInsert), delete(RowDelete) }; per-tab container dict keyed by tabId with arrays + computed dirtyCount.
2. `RowOperationsService`: 
   - `resolveEditability(tab, driver)` async -> EditabilityDecision: tableBrowse source + primaryKey(of:) lookup cached per table ref
   - staging API: stageCellEdit(tab,rowIndex,column,original,newValue) (reject if equal), stageRowDelete(rowIndex,pkValues), stageRowInsert(defaults from columns) → returns row template
   - revertCell / revertAll(tab)
   - `commit(tab)` async throws: build MutationStatements (updates grouped per row w/ all changed cols; inserts via InsertStatementBuilder; deletes via DeleteStatementBuilder), call driver.executeMutation sequentially per statement, on success clear staged for tab and signal refresh closure
3. `BrowseEditorViewModel`: exposes published-ish state for grid: isEditable + reason banner text; dirtyCount; handlers used by grid/context menus delegating to service; commit() wraps toast callback.
4. Tests with FakeDriver recording executeMutation calls: editability PK-less → readOnly reason verbatim from Kit rules; commit path builds expected statements (assert captured MutationStatement sql+batches); rollback propagation: executeMutation throwing → staged preserved + error rethrown; NULL transitions (string→null→'' cycles).
5. Commit "feat(app): row operations service with staged edits".

## Task C: Grid UI integration

1. ResultsGridView modifications:
   - double-click on cell when editable && browse mode → EditableCellView overlay (NSTextField): current rendered value (NULL shows empty w/ placeholder "NULL"), Enter stages (empty string vs NULL: checkbox/popup in overlay? v1: typing text = string; right-click Set NULL menu item toggles staged null), Esc discards
   - staged cell rendering: amber background tint + top-right dot
   - context menu on row: Delete Row(s) (multi-select support: enable multiple selection), Revert staged changes (cell-level when staged)
   - footer adds "● N staged ⌘S commit · revert all"
2. WorkspaceView keyboard: Cmd+S → vm.commit(); after successful commit auto reloadCurrentPage.
3. RootView/detail: read-only banner strip above results when decision != editable showing reason.
4. Acceptance: build/tests green (Kit now ~44+, app suite grows); launch probe. Live end-to-end edit verification happens in Batch 7 acceptance against docker DBs (documented).
5. Commits as noted.

## Final acceptance
Kit tests all green · app tests green · build · launch probe clean.
