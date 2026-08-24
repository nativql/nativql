# NativQL Batch 5 — Query Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans.

**Goal:** The core workspace per spec layout A — multi-tab, syntax-highlighted editor above a virtualized results grid; run selection/all with ⌘R/⌘↩; pagination + column-sort re-query.

**Architecture:** `WorkspaceViewModel` (@MainActor @Observable) owns tabs (`[QueryTab]`); each tab binds a connected connection id and holds editor text, cursor range, result (Loadable<QueryResult>), sort/pagination state. Editor = NSTextView wrapped (NSViewRepresentable) with a lightweight regex-based SQL syntax highlighter (keywords/types/strings/comments/numbers) + line-number ruler view. Grid = NSTableView wrapped for virtualization; cells display SQLValue rendering; NULL italic gray. Running uses driver.execute on selection or full text; statement under cursor via Kit splitter index tracking. Sort click → browse-style re-query is NOT applicable to arbitrary SQL; instead grid sort re-runs the last executed SELECT wrapping it as derived table ORDER BY? NO — spec says server-side sort via re-query for TABLE BROWSE; arbitrary query results sort client-side in v1 (document). Table browse mode: when selectedTable set (from Batch 4 stub), tab shows browseRows(sort:limit:offset) with real server sort + pagination.

**Tech Stack:** SwiftUI + AppKit bridges (NSTextView/NSTableView), drivers, Kit.

**Worktree:** `.worktrees/batch-5-workspace`, branch off main.
**Working dir:** `/Users/sipamungkas/Documents/projects/macos/nativql/.worktrees/batch-5-workspace`

---

## File Structure (locked)

```
NativQL/
├── State/QueryTab.swift                   # model: id, title, editorText, selectionRange, result state, browse state
├── State/Loadable.swift                   # exists
├── Services/SQLHighlighter.swift          # NSAttributedString regex highlighter (+ NSTextStorage helper)
├── ViewModels/WorkspaceViewModel.swift    # tabs CRUD, run logic, browse logic, pagination/sort
├── Views/Workspace/
│   ├── WorkspaceView.swift                # tab bar + split container (editor top / results bottom, VSplit like postgresgui ResizableSplitView pattern)
│   ├── TabBarView.swift                   # SwiftUI tab strip w/ close buttons, + button, dirty-free (v1 no dirty concept)
│   ├── QueryEditorView.swift              # NSViewRepresentable NSTextView + LineNumberRulerView, monospaced font from settings default
│   ├── Primitives/LineNumberRulerView.swift
│   └── Results/
│       ├── ResultsGridView.swift          # NSViewRepresentable NSTableView, virtualized, header sort indicators
│       ├── ResultsFooterView.swift        # row count · elapsed · page controls ‹ 1/7 › when browsing
│       └── CellContentView.swift          # table cell view rendering SQLValue (NULL italic gray "NULL")
NativQLTests/
└── WorkspaceTests.swift                   # VM logic: run-all/run-selection splitting, browse pagination math, sort mapping, tab lifecycle
```

## Task A: ViewModel core (TDD)

1. **QueryTab**: struct w/ UUID id, var title String (default "Query N"), editorText, selectedNSRange-ish (start/end Int), result: Loadable<QueryResult> = .idle, browse: BrowseState? (nil = free-query mode) where BrowseState { ref: TableRef, sort: SortSpec?, pageSize: Int = 200, pageIndex: Int, totalEstimate: Int64? }.
2. **WorkspaceViewModel** (@MainActor @Observable):
   - tabs management: openTab(for connectionId:) reuses single default tab per connection (spec: tabs bound to connection; v1 one tab per connection auto-created on connect, user can add more "+"); closeTab; activeTabId
   - `runActive()`: determine text = selection if non-empty else full editorText; statements = SQLStatementSplitter.split(text); empty → no-op; execute via manager.driver(for:)!.execute(joined statements) — NOTE driver.execute already handles multi-statement semantics; pass raw text (driver splits internally again — acceptable double-split, deterministic); set result .loading then .loaded/.error(message)
   - Browse mode helpers: `loadBrowsePage()` calling driver.browseRows(ref, sort:, limit: pageSize, offset: pageIndex*pageSize) into tab.result as RowPage→convert to QueryResult-shaped display (columns+rows, statementType .select); nextPage/prevPage guards; setSort(column) toggling asc/desc then reload page 0
   - `tableSelectionBinding` integration: AppState.selectedTable changes → open/reuse browse tab titled "db.tbl"
3. Unit tests (no live DB): run text resolution (selection vs all), browse pagination math (page bounds clamping), sort toggle mapping, tab reuse/open/close invariants, Loadable transitions. Driver calls behind a tiny protocol `DriverProviding` fake injected.
4. Commit "feat(app): workspace view models".

## Task B: Editor + highlighter

1. **SQLHighlighter**: pure function `highlight(_ ns: NSMutableAttributedString, scheme)` applying: keywords (SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE DROP ALTER VIEW INDEX PRIMARY KEY FOREIGN REFERENCES NOT NULL DEFAULT DISTINCT AS AND OR IN IS LIKE BETWEEN UNION ALL CASE WHEN THEN ELSE END EXPLAIN ANALYZE BEGIN COMMIT ROLLBACK SHOW DESCRIBE USE TRUNCATE) bold-or-colored; strings '…' one color; comments -- / /* */ another; numbers; identifiers-quoted. Case-insensitive keywords. Performance: apply only visible-range on change (simple full-pass OK ≤100k chars).
2. **QueryEditorView**: NSViewRepresentable hosting NSTextView: monospace font (Menlo 13 default), richText=false, autoGrammar=off, smart quotes/dashes off, delegate → VM binding editorText + selection range updates; ruler via LineNumberRulerView drawing line numbers aligned; horizontal scroll enabled (no wrap) via TextContainer width tracking; keyboard: Cmd+Enter/Cmd+R hook via performKeyEquivalent → viewModel.runActive().
3. LineNumberRulerView: standard implementation drawing count of lines from text.
4. Commit "feat(app): SQL editor with highlighting and line numbers".

## Task C: Results grid + wiring

1. **ResultsGridView**: NSTableView bridging: columns rebuilt from result.columns (identifier=name, width ~120 min, resizable); rows virtualized by dataSource count; cell = CellContentView(SQLValue); header click cycles sort when browse mode; copy support minimal (Edit menu copy of selected cell text via stringValue).
2. CellContentView: NSHostingView hosting small SwiftUI Text? Simpler: NSTextField non-editable styling NULL italic secondary color literal "NULL"; numbers right-aligned.
3. ResultsFooterView: SwiftUI overlay: "42 rows · 18 ms" or error text red; browse pages ‹ › + "page 2/7".
4. WorkspaceView: vertical split (editor flex 40% / results 60%) using simple GeometryReader + draggable divider (postgresgui's ResizableSplitView pattern reimplemented locally ~60 lines); TabBar on top; Cmd+T new tab.
5. Wire RootView detail: replace ConnectionDetailView placeholder body — keep header/disconnect, embed WorkspaceView(connectionId:) driven by appState.selectedTable → vm.openBrowse(tab) etc.
6. Acceptance: build green; tests green; launch probe; manual human verification later. Integration-gated UI-less test optional: run browse against live PG through VM with real driver (flagged).
7. Commit "feat(app): results grid, tabbed workspace, split layout".

## Final acceptance
Kit 40/40 · app tests green (+integration flag) · build · launch probe.
