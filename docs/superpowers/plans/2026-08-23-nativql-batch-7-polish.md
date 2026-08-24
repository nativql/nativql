# NativQL Batch 7 — History, Saved Queries, Export, DDL, Plans, Settings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans.

**Goal:** Final v1 feature pass — query history (auto-recorded, searchable), saved queries with folders, CSV/JSON export + whole-table export sheet, DDL viewer sheet, EXPLAIN tree view, settings, keyboard-shortcuts help, toasts.

**Architecture:** SwiftData store for history/saved/folders (spec decision); Kit exporters reused; EXPLAIN renders ExplainPlanNode as NSOutlineView-backed SwiftUI List tree; settings via standard Settings scene storing UserDefaults keys (rowLimit, queryTimeout, editorFontSize).

**Tech Stack:** SwiftData (macOS 14), Kit exporters, existing workspace components.

**Worktree:** `.worktrees/batch-7-polish`, branch off main.
**Working dir:** `/Users/sipamungkas/Documents/projects/macos/nativql/.worktrees/batch-7-polish`

---

## File Structure (locked)

```
NativQL/
├── Persistence/NativQLModelContainer.swift     # SwiftData container + models
├── Persistence/QueryHistoryEntry.swift         # @Model: sql, connectionName, kind, executedAt, durationMs, ok
├── Persistence/SavedQuery.swift                # @Model: name, sql, folderPath?, createdAt
├── Persistence/SavedFolder.swift               # @Model: name, parentPath? (path-string hierarchy, simple)
├── Services/HistoryRecorder.swift              # records after each runActive (fire-and-forget Task)
├── Services/ExportService.swift                # grid selection/page → CSV/JSON strings via Kit; file save via NSSavePanel
├── ViewModels/HistoryViewModel.swift           # search text filter, re-run action
├── ViewModels/SavedQueriesViewModel.swift      # CRUD + folder move
├── ViewModels/ExplainViewModel.swift           # run explain(analyze) → ExplainPlanNode root
├── Views/Workspace/ResultsGridExportMenu.swift # Export ▾ menu (CSV/JSON page or selection)
├── Views/Sheets/TableExportSheet.swift         # whole-table export w/ row limit field
├── Views/Sheets/DDLSheet.swift                 # monospace read-only text + copy button
├── Views/Sheets/ExplainSheet.swift             # plan tree list w/ rows/time columns
├── Views/Panels/HistoryPanel.swift             # sidebar-section or popover list
├── Views/Panels/SavedQueriesPanel.swift
├── Views/ShortcutsHelpView.swift               ⌘/ help window listing shortcuts
└── Views/ToastView.swift                        # bottom-center transient toasts (success commit/export)
NativQLTests/
└── PolishTests.swift                           # history recording, saved CRUD, export content paths, explain VM mapping
```

## Task A — Persistence + services (TDD)

1. SwiftData models per structure (keep @Model classes minimal; in-memory container for tests via ModelConfiguration(isStoredInMemoryOnly: true)).
2. HistoryRecorder: record(sql:connectionName:kind:result:) — skip empty/whitespace; cap table at 500 rows (delete oldest beyond).
3. ExportService: buildCSV(columns,rows)/buildJSON via Kit exporters; save(text:name:extension:) using NSSavePanel (panel presentation stays view-side; service returns string + suggested filename so tests avoid UI).
4. SavedQueries/Folders VMs: add/rename/delete/move-to-folder(listing grouped by folderPath).
5. Tests: history record+cap+search-filter logic; saved CRUD round-trip in-memory; export strings match Kit outputs for a sample result.
6. Commit "feat(app): history, saved queries, export services".

## Task B — UI integration

1. Workspace run pipeline: after execute completes (success OR failure), HistoryRecorder.fire(record). Re-run from history fills active tab editor.
2. Sidebar bottom section switcher (Tables / History / Saved) OR right-click tab bar → keep simple: two toggle buttons above sidebar footer switching tree vs HistoryPanel vs SavedQueriesPanel lists; history rows show snippet+time, double-click loads into active editor; saved rows support Run / Edit name / Delete / Move to folder.
3. Results footer Export ▾ menu: "Copy as CSV/JSON/INSERT" already exists for copy — extend menu with Save CSV/JSON of current page (or selection if any) via NSSavePanel runModal in view layer calling ExportService.
4. Table context menu in DatabaseTreeView: "Export Table…" opens TableExportSheet (limit field default 1000, blank=all) running browseRows looped pages up to limit then saving file; progress spinner while exporting.
5. Table context menu "View DDL" → DDLSheet loading driver.tableDDL; monospace, Copy button.
6. Toolbar/explain: when active tab result came from SELECT-ish statement enable "Explain ⌘E" → ExplainSheet runs driver.explain(sql, analyze: optionKey toggled by checkbox in sheet) rendering ExplainPlanNode tree (DisclosureGroup recursive; show operation, actualRows, actualTimeMs).
7. Toasts: ToastView overlay on WorkspaceView — success toast on commit ("3 changes applied") and exports; auto-dismiss 3s.
8. Settings scene (NativQLApp): editorFontSize slider 11–20 (editor reads UserDefaults onChange), default row limit for new tabs' BrowseState.pageSize, query timeout placeholder note (drivers don't implement timeout yet — store pref only, document).
9. ShortcutsHelp: ⌘/ opens window listing current shortcuts (⌘R/⌘↩ run, ⌘T new tab, ⌘S commit staged, ⌘E explain, ⌘/ this help).
10. Acceptance: xcodegen generate; Kit green; app suite green; build; headless launch probe clean.
11. Commits: "feat(app): history and saved queries", "feat(app): export, DDL, explain, toasts, settings".

Rules: macOS 14 SwiftData idioms (@Model, ModelContainer); views thin; no new deps; TDD where logic exists (services/VMs), views build+probe verified.
Report: Status + pasted outcomes + files changed + deviations + self-review