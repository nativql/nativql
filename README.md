# NativQL

A native macOS SQL client for **PostgreSQL** and **MySQL**. Fast, focused, and
fully local — connection details, queries, and results never leave your machine.

Built with SwiftUI + SwiftNIO drivers (no Electron, no C dependencies). Open
source under MIT.

## Features

**Connections**
- Profiles with host/port/user/password/database and per-engine SSL modes
- Paste a `postgres://` or `mysql://` connection string to fill the form
- Test-connection button, color labels, connect/disconnect from the sidebar

**Browsing**
- Sidebar: connections → databases → tables/views
- Schema-aware for PostgreSQL; flat database list for MySQL
- Lazy-loaded tree, refresh, drop database (with confirmation)

**Query workspace**
- Multi-tab interface — one click opens tabs per connection or per table
- Syntax-highlighted SQL editor (keywords/strings/comments/numbers) with line
  numbers and live font-size setting
- Run selection or everything (⌘R / ⌘↩); multi-statement scripts execute
  sequentially with the last result shown
- Query history auto-recorded (searchable, capped at 500) — double-click to
  reload into the editor
- Saved queries with folders: run, rename, move, delete

**Results grid**
- Virtualized NSTableView-backed grid stays fast on large pages
- NULL styled italic gray, distinct from empty strings; numbers right-aligned
- Copy rows as TSV; export current page as CSV/JSON; copy as CSV/JSON/INSERT
- Whole-table export to CSV/JSON with row limits and cancel support

**Inline editing**
- Double-click any cell in table browse mode to edit
- Staged changes show amber badges; ⌘S commits inside one transaction per group
- Primary-key-based UPDATE/INSERT/DELETE generation — tables without a primary
  key are read-only with a clear explanation why
- Add row (+ Row) and delete rows via context menu; Set NULL distinct from ""
- Zero-affected-row commits abort with a "row changed" warning instead of
  silently succeeding

**Query plans & DDL**
- EXPLAIN tree view: PostgreSQL `EXPLAIN (ANALYZE, FORMAT JSON)` and MySQL
  `EXPLAIN ANALYZE` — recursive plan tree with actual rows/timing (⌘E)
- View DDL for any table (`SHOW CREATE TABLE` / catalog reconstruction)

**Polish**
- Toast notifications for commits and exports
- Settings: editor font size (live), default browse page size
- Keyboard-shortcuts help window (⌘/)

## Architecture

```
Views (SwiftUI + AppKit bridges) → @Observable ViewModels → Services
    → DatabaseDriver protocol
           ↑                        ↑
   PostgresDriver            MySQLDriver
   (PostgresNIO)             (MySQLNIO)
```

Both drivers map wire types into one `SQLValue` enum, so everything above the
driver layer is database-agnostic. The star package graph keeps third-party
dependencies isolated:

```
NativQL.xcodeproj          # thin app shell (XcodeGen-generated, committed)
├── NativQL/               # app target: Services, Persistence, ViewModels, Views
├── Packages/
│   ├── NativQLKit/        # pure logic: models, driver protocol, SQL utilities
│   ├── PostgresDriver/    # DatabaseDriver over PostgresNIO (~1.33)
│   └── MySQLDriver/       # DatabaseDriver over MySQLNIO (~1.9)
└── docker-compose.yml     # postgres:16 + mysql:8 for integration tests
```

## Quick start

Requirements: macOS 14+, Xcode 15.3+ (or newer, incl. Xcode 26),
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

**Build and launch with one command:**

```bash
make run
```

Generates the Xcode project if needed, builds Debug into `.derived/`, opens the
app. Also available:

```bash
make build    # compile without launching
make test     # NativQLKit unit test suite
make clean    # remove build artifacts
```

**Prefer Xcode?**

```bash
git clone https://github.com/nativql/nativql.git && cd nativql && open NativQL.xcodeproj
```

Then: select the **NativQL** target → Signing & Capabilities → pick your team
(a free "Personal Team" works) → ⌘R.

**Testing**

```bash
make test                                  # fast unit tests (153 tests)
docker compose up -d                       # start postgres:16 + mysql:8
TEST_RUNNER_NATIVQL_INTEGRATION=1 \
  xcodebuild -project NativQL.xcodeproj -scheme NativQL test CODE_SIGNING_ALLOWED=NO
                                           # full suite incl. live round-trips
# driver packages also test standalone:
(cd Packages/PostgresDriver && NATIVQL_INTEGRATION=1 swift test)
(cd Packages/MySQLDriver    && NATIVQL_INTEGRATION=1 swift test)
```

Note: the MySQL container's `nativql` user needs `CREATE/DROP` grants outside
its own database for admin round-trip tests — see docker-compose comments.

## Security notes

v1 stores connection passwords in plaintext JSON under
`~/Library/Application Support/NativQL/connections.json` (chmod 600). This is a
known tradeoff; Keychain integration is planned. Query history stores SQL text,
so credentials pasted into queries would persist there too. Avoid v1 on shared
machines if this matters to you.

## Known limitations (v1)

- No SSH tunneling yet (planned v1.x)
- Passwords not stored in Keychain yet (planned v1.x)
- No smart autocomplete (planned v1.x)
- MySQL: zero-row SELECTs return no column headers (library limitation);
  TIME values beyond ±24h supported but microseconds truncated
- Multi-statement commits run as separate transactions per statement group
- Query timeout preference is stored but not yet enforced by drivers

## Roadmap

| Milestone | Status |
|---|---|
| Foundation: packages, models, driver protocol, SQL utilities | ✅ |
| PostgreSQL driver (22 integration tests) | ✅ |
| MySQL driver (21 integration tests) | ✅ |
| Connections UI, sidebar, welcome screen | ✅ |
| Tabs, editor, virtualized results grid | ✅ |
| Inline editing with staged transactional commits | ✅ |
| History, saved queries, export, DDL, EXPLAIN, settings | ✅ |
| v1.x: SSH tunnels · Keychain · autocomplete · import · ER diagrams | planned |

## License

[MIT](LICENSE)
