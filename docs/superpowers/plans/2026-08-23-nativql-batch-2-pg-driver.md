# NativQL Batch 2 — PostgreSQL Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully implement `DatabaseDriver` for PostgreSQL over PostgresNIO, integration-tested against a real server in Docker.

**Architecture:** `PostgresConnection` (single connection per driver instance, held long-term per tab). All SQL emitted by the driver is parameterized or identifier-quoted via one internal helper. Type mapping funnels every cell through the Kit `SQLValue` enum. Integration tests run real round-trips against `localhost:55432` (docker-compose from Batch 1), gated behind `NATIVQL_INTEGRATION=1`.

**Tech Stack:** PostgresNIO ~>1.x (SPM), NIOSSL (transitive), XCTest.

**Worktree:** `.worktrees/batch-2-pg-driver`, branch `batch-2-pg-driver` off main.
**Working dir:** `/Users/sipamungkas/Documents/projects/macos/nativql/.worktrees/batch-2-pg-driver`

---

## File Structure (locked)

```
Packages/PostgresDriver/
├── Package.swift                          # adds PostgresNIO dep + test target
├── Sources/PostgresDriver/
│   ├── PostgresDriver.swift               # final class PostgresDriver: DatabaseDriver
│   ├── PostgresConfiguration+TLS.swift    # SSLMode → PostgresNIO TLS mapping
│   ├── SQLValueMapper.swift               # PostgresCell → SQLValue (+ reverse binding)
│   ├── IdentifierQuoting.swift            # "ident" quoting helper
│   ├── Introspection.swift                # extension: databases/tables/columns/PK/DDL
│   ├── ExplainParser.swift                # EXPLAIN FORMAT JSON → ExplainPlanNode
│   └── MutationExecutor.swift             # transactional batch execution
└── Tests/PostgresDriverTests/
    ├── UnitTests.swift                    # ExplainParser, quoting, mapper pure parts
    └── IntegrationTests.swift             # NATIVQL_INTEGRATION=1 gated round-trips
```

Delete `Sources/PostgresDriver/Placeholder.swift`.

## Task A: Package setup + connection lifecycle

- Update Package.swift: add `.package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0")`, product dep on target; add test target.
- `PostgresDriver.swift`: `public final class PostgresDriver: DatabaseDriver, @unchecked Sendable`. Holds `private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)`, optional `PostgresConnection`, `connectionPID: Int32?`, config cache. Implement:
  - `connect(_:)`: build `PostgresConnection.Configuration(host:port:username:password:database:tls:)` from ConnectionConfig (password nil → empty string; sslMode → TLS policy per helper). Connect, then `SELECT pg_backend_pid()::int4` → store PID. Throw DriverError.connectionFailed / .authenticationFailed / .tlsFailed by inspecting thrown error text (contains "authentication" / password → authFailed; "ssl"/"tls" → tlsFailed; else connectionFailed).
  - `disconnect()`: close if connected, nil out state. `isConnected()`.
  - `testConnection` override not needed (default suffices).
  - deinit: attempt sync-ish best-effort close is NOT possible with async API — document that callers must call disconnect(); keep eventLoopGroup alive until disconnect then shut it down.
- `PostgresConfiguration+TLS.swift`: map SSLMode → `PostgresConnection.Configuration.TLS`: disable→.disable, prefer→.prefer(try makeContext()), require→.require(makeContext()), verifyCA→.require(context w/ .fullVerification? NO — verifyCA needs cert check but NOT hostname; NIOSSL CertificateVerification.fullVerification does hostname too. Use .require with context configured `certificateVerification = .noHostnameVerification`... NIOSSL lacks no-hostname option publicly in older versions; pragmatic v2 mapping: verifyCA == fullVerification minus hostname is unsupported by NIOSSL → treat verifyCA as fullVerification and note limitation in doc comment), verifyFull→.require(NIOSSLContext(.client, verification:.fullVerification)).
  - Prefer without context: PostgresNIO's `.prefer(nil)` handles opportunistic TLS internally when nil context passed.
- **Integration harness** in `IntegrationTests.swift`:
  ```swift
  func makeLiveDriver() throws -> PostgresDriver // skips unless env set
  ```
  Env gate pattern:
  ```swift
  guard ProcessInfo.processInfo.environment["NATIVQL_INTEGRATION"] == "1" else {
      throw XCTSkip("set NATIVQL_INTEGRATION=1")
  }
  ```
  Config: host 127.0.0.1, port 55432, user/pass nativql, db nativql_test, sslMode .disable.
- Acceptance: `swift build` green; `NATIVQL_INTEGRATION=1 swift test` connects, asserts pid > 0, disconnects; plain `swift test` skips all integration tests. Commit.

## Task B: Query execution + type mapping

- `SQLValueMapper.swift`:
  - Cell → SQLValue by column data type string (from RowDescription): int2/int4/int8 → .int; float4/float8 → .double; numeric → .decimal(raw text via cell description/string); bool → .bool; date → .date; timestamp/timestamptz → .datetime; time/timetz → .time(seconds); json/jsonb → .json(raw text); bytea → .bytes; uuid/money/xml/inet/cidr/interval/everything else → .string. NULL cell → .null regardless.
  - Reverse: SQLValue → bindable value for query parameters (used by mutation path): null→PostgresNIO null, bool/int/double pass-through, decimal/string/json as strings, dates as ISO-ish strings acceptable to PG (or use native date types — implementer picks what compiles cleanly against PostgresNIO API and documents).
- `execute(_ sql:)`:
  - Split via Kit `SQLStatementSplitter`; empty → return empty QueryResult(statementType: .other).
  - Execute statements sequentially on the connection. Track last row-producing result (columns+rows) and cumulative affectedRows for INSERT/UPDATE/DELETE via command tags. Measure total executionMilliseconds with ContinuousClock.
  - Map final statementType via Kit QueryTypeDetector on the LAST statement.
  - Task cancellation → throw DriverError.cancelled.
  - Errors → map to DriverError.queryFailed(postgres message).
- Acceptance: unit tests for mapper pure functions where feasible; integration test creates table, inserts via execute, SELECTs back verifying int/text/bool/null/numeric/json mappings; multi-statement script returns last SELECT; syntax error throws queryFailed containing PG message. Commit.

## Task C: Introspection

- `IdentifierQuoting.swift`: quote(_) doubling embedded quotes.
- `Introspection.swift` extension on PostgresDriver:
  - `listDatabases()`: `SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname`
  - `listTables(database:schema:)`: current database only (ignore database arg mismatch by filtering); schema nil → non-system schemas (schemaName <> 'pg_catalog' AND <> 'information_schema' AND NOT LIKE 'pg\_%'); join pg_class reltuples for estimates; relkind r→table, v→view, m→matview (TableInfo.Kind.table/.view).
  - `listColumns(_:)`: information_schema.columns for the table (schema default 'public'), ordered by ordinal_position; is_nullable YES→true; PK flag filled from primaryKey lookup; data_type mapped verbatim.
  - `primaryKey(of:)`: pg_index indisprimary over pg_attribute; returns array of att names in index order; nil when none.
  - `tableDDL(_:)`: reconstruct CREATE TABLE: columns w/ type + NOT NULL + DEFAULT (skip nextval() sequence defaults → emit GENERATED note? keep raw default text), PRIMARY KEY clause from pk columns, trailing `;`. Doc comment: reconstruction, not byte-exact pg_dump.
- Acceptance: integration tests create schema fixture (two schemas, tables incl. composite PK) and assert lists/filters/PK order/DDL contains expected clauses. Commit.

## Task D: Browse, explain, admin, mutations, cancel

- `browseRows(_:sort:limit:offset:)`: build `SELECT * FROM q(schema).q(name)` + optional `ORDER BY q(col) ASC|DESC` + LIMIT/OFFSET; run; wrap into RowPage with totalCountEstimate from reltuples (best effort).
- `ExplainParser.swift`: parse PG `EXPLAIN (FORMAT JSON)` shape `[{ "Plan": {…recursive…}, "Planning Time":.., "Execution Time":.. }]` → ExplainPlanNode(operation: "Node Type", detail: extra info joined, actualRows: "Actual Rows", actualTimeMilliseconds: "Actual Total Time", children recursive).
- `explain(_:analyze:)`: run `EXPLAIN (ANALYZE<, FORMAT JSON>) <sql>`; parse first row first column (jsonb → .json text) via parser.
- Admin: `createDatabase(named:)` → `CREATE DATABASE "x"` (must run on current conn; fine), `dropDatabase(named:)` → `DROP DATABASE "x" WITH (FORCE)`.
- `MutationExecutor.swift`: `executeMutation(_ statement:)`: BEGIN; for each batch bind ANSI ? placeholders → $n positional params with mapped values, execute statement.sql; accumulate command-tag affected rows (parse tag "UPDATE n"); COMMIT; on error ROLLBACK and rethrow mutationFailed. Return total.
- `cancelRunningQuery()`: lazily open a short-lived control connection (same config), run `SELECT pg_cancel_backend($pid)`, close control connection. If no running query, harmless no-op. Never mutate primary connection state.
- Acceptance: integration tests cover browse sort/pagination windows, EXPLAIN tree parse on real plan, mutation transaction rollback on bad batch (assert zero rows persisted), cancel aborts a `SELECT pg_sleep(10)`. Commit.

## Final acceptance (whole batch)

```bash
(cd Packages/NativQLKit && swift test) && \
(cd Packages/PostgresDriver && swift build) && \
NATIVQL_INTEGRATION=1 (cd Packages/PostgresDriver && swift test) && \
xcodebuild -project ../../NativQL.xcodeproj -scheme NativQL test CODE_SIGNING_ALLOWED=NO
```

All green → merge-ready.
