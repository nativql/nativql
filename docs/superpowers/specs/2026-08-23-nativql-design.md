# NativQL — Design Specification

**Date:** 2026-08-23
**Status:** Approved design, pending implementation plan

## Overview

NativQL is a native macOS SQL client (SwiftUI) in the spirit of TablePlus and
[PostgresGUI](https://github.com/PostgresGUI/postgresgui). v1 targets **PostgreSQL**
and **MySQL** behind a single `DatabaseDriver` protocol so additional engines
(e.g., SQLite) can be added without architectural change.

Open source first: contributors clone the repo, open `NativQL.xcodeproj`,
set a signing team, and press Cmd+R — the postgresgui model. App Store
distribution is a later goal; licensing decisions respect that (no GPL).

## Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Driver technology | Pure Swift NIO drivers (PostgresNIO + MySQLNIO, both MIT) | Zero C deps, SPM-native, async/await, App Store-safe |
| SSH tunnels | Deferred to v1.x | Largest complexity item; isolated module later |
| Password storage | Plaintext JSON file (v1), Keychain deferred | User decision; documented tradeoff, upgrade path kept |
| Data editing | Inline cell editing (TablePlus-style) | Core UX requirement |
| Main layout | Vertical split: editor above results, per tab | Matches TablePlus/postgresgui |
| Name | NativQL | Verified collision-free |
| Distribution | Open source now, App Store later | MIT license |

## Non-Goals (v1)

SSH tunneling, Keychain storage, smart autocomplete, data import, ER diagrams,
engines beyond PostgreSQL/MySQL.

## Architecture

Four layers, strict downward dependency:

```
Views (SwiftUI)
  ↓
ViewModels (@Observable)
  ↓
Services (Connection, Query, Metadata, RowOps, Export)
  ↓
DatabaseDriver protocol
  ↑                 ↑
PostgresDriver   MySQLDriver
(PostgresNIO)    (MySQLNIO)
```

### Normalization layer

Both drivers map wire types into one `SQLValue` enum:

```swift
enum SQLValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)        // DATE
    case time(TimeInterval)
    case datetime(Date)    // TIMESTAMP / DATETIME
    case json(String)      // JSON/JSONB raw text for viewer
    case bytes(Data)
}
```

Every view, exporter, and editor above the driver layer is database-agnostic.

### DatabaseDriver protocol surface

```swift
protocol DatabaseDriver: Sendable {
    var kind: DatabaseKind { get }          // .postgres | .mysql

    func connect(_ config: ConnectionConfig) async throws
    func disconnect() async
    func testConnection(_ config: ConnectionConfig) async throws

    func execute(_ sql: String) async throws -> QueryResult   // multi-statement aware
    func cancelRunningQuery() async

    // Introspection
    func listDatabases() async throws -> [DatabaseInfo]
    func listTables(database: String, schema: String?) async throws -> [TableInfo]
    func listColumns(_ table: TableRef) async throws -> [ColumnInfo]
    func tableDDL(_ table: TableRef) async throws -> String
    func primaryKey(of table: TableRef) async throws -> [String]?

    // Browsing & editing
    func browseRows(_ table: TableRef, sort: SortSpec?, limit: Int,
                    offset: Int) async throws -> RowPage
    func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode

    // Admin
    func createDatabase(name: String) async throws
    func dropDatabase(name: String) async throws

    // Mutations — statements built by RowOperationsService, driver binds
    // values and executes each batch inside a transaction.
    func executeMutation(_ statement: MutationStatement) async throws -> Int
}
```

Exact signature shape may shift during planning; the boundary is fixed:
the service builds dialect-correct parameterized statements, the driver binds
and executes them transactionally.

### Engine specifics

| Concern | PostgreSQL (pg_catalog / information_schema) | MySQL (information_schema) |
|---|---|---|
| Schema grouping | `schemata` (public, custom schemas) | databases = schemas, flat list |
| DDL | Reconstructed from catalogs | `SHOW CREATE TABLE` |
| Explain | `EXPLAIN (ANALYZE?, FORMAT JSON)` → tree | `EXPLAIN ANALYZE` (8.0+) → tree |
| Cancellation | Native cancel protocol on same channel | `KILL QUERY <id>` via side connection |
| Auth | md5 / SCRAM-SHA-256 | caching_sha2_password, mysql_native_password |
| SSL modes | disable, prefer, require, verify-ca+hostname | disabled, preferred, required, verify_ca, verify_identity |

## Inline Editing Model

- Browse mode = generated `SELECT * FROM t ORDER BY pk LIMIT n OFFSET m`
  (column click re-queries server-side with new sort).
- **Editability rules:** results are editable only when they come from table
  browse or a single-table SELECT without joins/aggregates/GROUP BY/DISTINCT,
  AND the table has a primary key. Otherwise read-only banner explains why.
- Cell edit → **staged change**: grid shows dirty marker, original value kept.
- ⌘S commit → `RowOperationsService` builds parameterized
  `UPDATE t SET col=? WHERE pk=?` (and `INSERT`/`DELETE ... WHERE pk IN (...)`)
  → executed inside a transaction → success refreshes rows + toast; failure
  keeps staged changes for retry.
- NULL vs empty-string are distinct states in the cell editor.
- Multi-row delete requires confirmation showing row count.

## v1 Feature Set

| Area | Features |
|---|---|
| Connections | Profiles (host/port/user/password/db), full SSL mode sets, `postgres://`/`mysql://` URL import, test button, color labels |
| Sidebar | Connections → databases → tables/views; PG grouped by schema, MySQL flat; context menus (view DDL, export table) |
| Tabs | Multi-tab workspace; each tab bound to a connection; state restored on relaunch |
| Editor | Syntax highlighting, line numbers, run selection/all (⌘R, ⌘↩), sequential multi-statement execution, query type detection |
| Results | Virtualized NSTableView-backed grid, column-sort re-query, pagination controls, NULL italic styling, long-text/JSON cell popover viewer, copy cell/row/selection as CSV/JSON/INSERT |
| Editing | Full inline model above |
| Queries | Auto-recorded searchable history; saved queries with nested folders; move-to-folder |
| Export | CSV/JSON from results grid; whole-table export sheet with row limits |
| Schema ops | DDL sheet, columns/structure view, create/drop database |
| Plans | EXPLAIN tree view for both engines |
| Polish | Welcome screen w/ recent connections, Settings (font size, default row limit, query timeout), keyboard shortcuts help, mutation toasts |

Deferred to v1.x: SSH tunnels, Keychain, autocomplete, import, ER diagrams.

## Persistence

- **Connections:** `~/Library/Application Support/NativQL/connections.json`,
  chmod 600. Passwords stored inline as plaintext — accepted v1 tradeoff,
  documented in README security section. Schema versioned for migration.
- **History / saved queries / folders / tab state:** SwiftData store
  (`default.store` in same directory).
- **Preferences:** UserDefaults (`rowLimit`, `queryTimeout`, `editorFontSize`,
  theme follows system).

## Error Handling

- Typed errors per layer: `DriverError` (protocol-level),
  `ConnectionError` (dial/auth/SSL), `QueryError` (syntax, cancelled, timeout),
  surfaced through status banner + toasts with engine message text preserved.
- Connection loss detection → banner with one-click reconnect.
- Query timeout configurable; cancellation always available (⌘.).

## Testing Strategy

1. **Unit tests** (fast, no I/O): SQLStatementSplitter, ConnectionStringParser,
   QueryTypeDetector, EditabilityRules, result normalizer, CSV/JSON exporters,
   RowOperationsService statement generation. Live in `Packages/NativQLKit/Tests`.
2. **Integration tests** (Docker): `docker-compose.yml` runs `postgres:16` +
   `mysql:8`. Driver packages run real connect/introspect/browse/edit round-trips.
   Gated by `NATIVQL_INTEGRATION=1`; skipped otherwise so `swift test` passes
   anywhere. Live in `Packages/*/Tests`.
3. **App tests:** light smoke coverage of view models in Xcode test target.

CI (GitHub Actions): macOS runner, build app target + run unit tests on every PR;
integration job when Docker matrix is feasible.

## Project Structure

```
nativql/
├── NativQL.xcodeproj              # Thin: app target + app tests only
├── Packages/
│   ├── NativQLKit/                # Pure logic — zero external deps, no NIO
│   ├── PostgresDriver/            # DatabaseDriver impl over PostgresNIO
│   └── MySQLDriver/               # DatabaseDriver impl over MySQLNIO
├── NativQL/                       # App target (glue only)
│   ├── Services/
│   ├── Persistence/
│   ├── ViewModels/
│   ├── Views/{Sidebar,TabBar,Editor,ResultsGrid,Sheets}/
│   └── NativQLApp.swift
├── docker-compose.yml
├── .github/workflows/ci.yml
├── README.md · LICENSE (MIT) · .gitignore
```

Star dependency graph: `PostgresDriver` and `MySQLDriver` depend only on
`NativQLKit`; nothing depends on the app target. Drivers can be built/tested
with plain `swift build` / `swift test` — Xcode required only for the app shell.

## Platforms & Dependencies

- macOS 14+ (Sonoma), SwiftUI + `@Observable`, Swift 5.10+/6 toolchain.
- PostgresNIO ~>1.x · MySQLNIO ~>1.x (SPM, pinned upToNextMajor).
- No other runtime dependencies.

## Open Questions

None — all resolved during brainstorming.
