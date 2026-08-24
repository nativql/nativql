# NativQL Batch 4 — Connections, Sidebar & Welcome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Working app shell — persistent connection profiles, connect/disconnect via drivers, sidebar browsing connections→databases→tables, welcome screen, connection form with URL paste + test button.

**Architecture:** `ConnectionStore` persists profiles to `~/Library/Application Support/NativQL/connections.json` (chmod 600, schema version field). `DatabaseConnectionManager` (app-level actor-ish class) owns one connected driver instance per profile id and exposes async ops to view models. SwiftUI `@Observable` state objects; NavigationSplitView with sidebar (layout A from spec). Views are thin; logic lives in testable view models/services.

**Tech Stack:** SwiftUI (macOS 14+), @Observable, both driver packages, XCTest for logic layers.

**Worktree:** `.worktrees/batch-4-app-shell`, branch off main.
**Working dir:** `/Users/sipamungkas/Documents/projects/macos/nativql/.worktrees/batch-4-app-shell`

---

## File Structure (locked)

```
NativQL/
├── NativQLApp.swift                       # rewrite: @main app w/ AppState environment
├── Persistence/ConnectionStore.swift      # load/save/versioned/chmod 600
├── Services/DatabaseConnectionManager.swift
├── State/AppState.swift                   # @Observable root state
├── ViewModels/
│   ├── SidebarViewModel.swift
│   ├── ConnectionFormViewModel.swift
│   └── DatabaseTreeViewModel.swift        # per-connection db/table tree loading
└── Views/
    ├── RootView.swift                     # NavigationSplitView shell
    ├── Welcome/WelcomeView.swift          # recent connections grid + new-connection CTA
    ├── Sidebar/SidebarView.swift          # connections list + selected tree
    ├── Sidebar/DatabaseTreeView.swift     # databases → tables/views disclosure groups
    └── ConnectionForm/ConnectionFormView.swift  # sheet: fields + SSL picker + color + test + save
NativQLTests/
└── AppShellTests.swift                    # store round-trips, manager lifecycle, form VM validation
```

## Task A: Persistence + connection management services (TDD)

1. **ConnectionStore**: 
   - `struct ConnectionStoreDocument: Codable { var schemaVersion: Int = 1; var connections: [ConnectionConfig] }`
   - `final class ConnectionStore`: init(directory: FileManager searchPath default) injectable for tests; `load() -> [ConnectionConfig]` (missing file → [], corrupt → [] + log); `save(_:) throws`; atomic write (tmp+rename); chmod 600 via POSIX after write (best-effort, ignore failure in tests' temp dirs).
   - CRUD helpers: add/update/remove by id.
2. **DatabaseConnectionManager** (`@MainActor final class`, holds `[UUID: any DatabaseDriver]`):
   - `func connect(_ config: ConnectionConfig) async throws` — instantiate PostgresDriver()/MySQLDriver() by kind, connect, store
   - `func disconnect(_ id: UUID)`, `func isConnected(_ id:) -> Bool`, `driver(for id:) -> (any DatabaseDriver)?`
   - `func test(_ config:) async throws` — throwaway instance, never stored
   - `disconnectAll()` for app quit
   - Reconnect semantics: connecting an already-connected id tears down first (mirror driver behavior).
3. Unit tests (AppShellTests.swift): store round-trip incl. special chars in passwords; corrupt file → empty; add/update/remove; manager connect against live docker DBs gated NATIVQL_INTEGRATION=1 (postgres 55432 + mysql 53306) verifying isConnected/driver(for:)/test-failure path; test() with bad creds throws.
4. Acceptance: swift build; Kit untouched 40/40; app tests green (+ integration when flagged). Commit "feat(app): connection persistence and driver manager".

## Task B: State, view models, UI (build-verified)

1. **AppState** (@Observable): `connections: [ConnectionConfig]`, `connectionStates: [UUID: ConnectionState]` where enum ConnectionState { disconnected, connecting, connected, failed(String) }; selectedConnectionId; delegates to store+manager. Methods: refresh/save/delete/connect/disconnect.
2. **SidebarViewModel**: given a connected driver → loads databases (`listDatabases`) then lazily per database loads tables (`listTables(database:schema:nil)`) into a tree model `[DatabaseNode]` where DatabaseNode { name, tables: Loadable<[TableInfo]> } (Loadable enum idle/loading/loaded/error). Expand-on-demand.
3. **Views**:
   - RootView: NavigationSplitView { sidebar } detail { WelcomeView or connection detail placeholder ("select a table" empty state — real query workspace arrives Batch 5) }
   - SidebarView: bottom toolbar +/- buttons; rows show color dot, name, kind icon, status spinner/checkmark/error; context menu Connect/Disconnect/Edit/Delete; selection drives detail
   - DatabaseTreeView: disclosure groups per database; table/view icons; clicking a table sets a stub "selectedTable" binding (workspace consumes it in Batch 5); context menu on database: Create Table? NO v1 — only Refresh; on database row also Drop Database (confirm dialog)
   - ConnectionFormView (sheet): fields name/host/port(auto from kind)/user/password(secure)/database(optional)/SSL picker (modes per kind)/color swatches row; "Paste URL…" button using ConnectionStringParser filling fields; Test button showing inline result; Save validates non-empty name/host/user
   - WelcomeView: app title, "New Connection" prominent button, grid of saved profiles (color dot + name + host) that connect on click
   - Error surfacing: .alert from failed states
4. **App wiring**: NativQLApp creates AppState (loads store), environmentObject-style injection via .environment(appState); window min sizes kept; Cmd+Q triggers disconnectAll via scene phase handler.
5. Acceptance: xcodegen generate; xcodebuild build CODE_SIGNING_ALLOWED=NO green; launch app once headlessly (open + pgrep + quit). Commit "feat(app): sidebar, welcome screen, connection form".

## Final acceptance

```bash
(cd Packages/NativQLKit && swift test) && \
xcodebuild -project NativQL.xcodeproj -scheme NativQL test CODE_SIGNING_ALLOWED=NO | tail -1 && \
open .derived/Build/Products/Debug/NativQL.app && sleep 3 && pgrep -x NativQL && osascript -e 'tell application "NativQL" to quit'
```
