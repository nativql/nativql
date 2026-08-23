# NativQL Batch 3 — MySQL Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully implement `DatabaseDriver` for MySQL over MySQLNIO, integration-tested against the dockerized MySQL 8 from Batch 1.

**Architecture:** Mirror of Batch 2's shape (single long-lived connection per driver instance, catalog-driven introspection, transactional mutation executor) with MySQL-specific substitutions: backtick quoting, `information_schema` + `SHOW CREATE TABLE`, `EXPLAIN ANALYZE` tree parsing, `KILL QUERY` via side connection, MySQL SSL modes. Reuse Kit utilities; do NOT copy PG wire-format decoders.

**Tech Stack:** MySQLNIO ~>1.x (SPM), XCTest. Live server: `127.0.0.1:53306` user/pass nativql db nativql_test (root password also nativql — needed only if tests must create/drop databases; grant checks first).

**Worktree:** `.worktrees/batch-3-mysql-driver`, branch off main.
**Working dir:** `/Users/sipamungkas/Documents/projects/macos/nativql/.worktrees/batch-3-mysql-driver`

---

## File Structure (locked)

```
Packages/MySQLDriver/
├── Package.swift                          # MySQLNIO dep + test target
├── Sources/MySQLDriver/
│   ├── MySQLDriver.swift                  # final class MySQLDriver: DatabaseDriver
│   ├── MySQLConfiguration+TLS.swift       # SSLMode → MySQLNIO TLS mapping
│   ├── SQLValueMapper.swift               # column-type → SQLValue (+ reverse bind)
│   ├── IdentifierQuoting.swift            # `ident` backtick quoting
│   ├── Introspection.swift                # databases/tables/columns/PK/DDL
│   ├── ExplainParser.swift                # EXPLAIN ANALYZE (tree text or JSON) → ExplainPlanNode
│   └── MutationExecutor.swift             # transactional batches (? binds native)
└── Tests/MySQLDriverTests/
    ├── UnitTests.swift
    └── IntegrationTests.swift             # NATIVQL_INTEGRATION=1 gated
```

Delete `Sources/MySQLDriver/Placeholder.swift`.

## Engine notes driving decisions

- MySQL "database" == schema; sidebar shows databases flat. TableRef.schema holds the database name.
- Quoting: `` `ident` `` doubling embedded backticks.
- PK lookup: information_schema.KEY_COLUMN_USAGE WHERE CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION (or STATISTICS INDEX_NAME='PRIMARY').
- tableDDL: `SHOW CREATE TABLE `db`.`tbl`` → return Create Table column verbatim.
- EXPLAIN ANALYZE (8.0+): returns a single-row text tree ("-> Nested loop ... (cost=.. rows=..) (actual time=..rows=..loops=..)"). Parse indentation-based tree into ExplainPlanNode; actual rows/time from `(actual time=… rows=… loops=…)`. If JSON variant available (`EXPLAIN ANALYZE FORMAT=JSON`), prefer it and reuse a JSON parser shaped like PG's Plan node where feasible — implementer picks ONE approach, documents it, and writes unit fixtures against real output captured from the live server during development.
- Cancellation: side connection runs `KILL QUERY <connectionId>`; obtain own id at connect via `SELECT CONNECTION_ID()`. Map MySQL error 1317 (query interrupted) → .cancelled.
- Affected rows: MySQLNIO result exposes affectedRows on command success — no tag parsing needed.
- Multi-statement execute: same semantics as PG task B (splitter, last row-producing result, cumulative affectedRows). MySQLNIO supports multi-statements only when enabled in connection config — enable it or split client-side (client-side split preferred for consistency).
- Type mapping: TINYINT/SMALLINT/INT/BIGINT→int; FLOAT/DOUBLE→double; DECIMAL/NUMERIC→decimal raw text; BOOL/TINYINT(1) caveat → treat as int unless column type says bool (document); DATE→date; DATETIME/TIMESTAMP→datetime; TIME→time seconds; JSON→json; BLOB/BINARY/VARBINARY→bytes; CHAR/VARCHAR/TEXT/ENUM/SET/etc→string. NULL→.null.
- TLS: disabled/preferred/required/verify_ca/verify_identity mapped onto MySQLNIO's TLS configuration (.disabled / .preferred(...) / .required(...) / .verifyIdentity etc. per pinned API); verifyCA uses certificateVerification without hostname when API permits.
- Auth: container configured with caching_sha2_password default + mysql_native_password flag available; integration config uses nativql user.

## Task A: Package setup + connection lifecycle

- Package.swift w/ MySQLNIO dep + test target; delete placeholder.
- MySQLDriver class mirroring PostgresDriver patterns (ELG ownership, disconnect-before-reconnect, failed-connect cleanup, @unchecked Sendable doc, deinit contract). Capture CONNECTION_ID() at connect. Error classification: access denied → .authenticationFailed; TLS-related → .tlsFailed; else .connectionFailed.
- Integration harness identical gate pattern; port 53306.
- Tests: connect→id>0→disconnect; bad password → authFailed; wrong port → connectionFailed; reconnect idempotent.
- Commit: "feat(mysql-driver): package setup, connection lifecycle, TLS mapping"

## Task B: Query execution + type mapping

- SQLValueMapper per engine notes above; pure/static core + unit tests incl. reverse binding (SQLValue → MySQLNIO bindable; dates as ISO-ish strings if pragmatic — document).
- execute(): splitter → sequential; last row-producing result wins; cumulative affectedRows from MySQLNIO metadata; ContinuousClock timing; error mapping (ER syntax error → .queryFailed w/ message; 1317 → .cancelled; task cancel → .cancelled).
- Integration: full-type round-trip table (mirror PG t_types with MySQL types), multi-statement script, syntax error mapping.
- Commit: "feat(mysql-driver): query execution and SQLValue type mapping"

## Task C: Introspection

- IdentifierQuoting (backticks) + Introspection extension:
  - listDatabases(): SHOW DATABASES filtered (skip information_schema, mysql, performance_schema, sys)
  - listTables(database:schema:): schema IS the database; information_schema.TABLES TABLE_ROWS estimate; BASE TABLE→table, VIEW→view
  - listColumns: information_schema.COLUMNS ordered by ORDINAL_POSITION; is_nullable YES→true; EXTRA contains auto_increment note in defaultValue? keep defaultValue raw; PK flags from PRIMARY key lookup
  - primaryKey(of:) as engine notes
  - tableDDL via SHOW CREATE TABLE (return verbatim)
- Integration fixture mirrors batch-2-C shape (schema b3c_test; users w/ identity PK; orders composite PRIMARY KEY(id,user_id); no_pk table; a view). Same assertion style.
- Commit: "feat(mysql-driver): catalog introspection with SHOW CREATE TABLE"

## Task D: Browse, explain, admin, mutations, cancel

- browseRows: ORDER BY backtick-quoted col ASC|DESC + LIMIT/OFFSET; estimate via TABLE_ROWS.
- ExplainParser: parse chosen EXPLAIN ANALYZE format into tree; unit fixtures from REAL captured output.
- Admin: CREATE/DROP DATABASE (backtick-quoted; DROP DATABASE IF NOT exists semantics: plain DROP DATABASE).
- MutationExecutor: BEGIN; batches bound natively with ? placeholders (NO rewriter needed — statement.sql already ANSI ?; MySQLNIO binds positionally); COMMIT; ROLLBACK+throw .mutationFailed on failure; sum affectedRows. Unit-test any helper logic; integration mirror batch-2-D incl. rollback-on-violation and persistence assertions.
- cancelRunningQuery(): side connection KILL QUERY <id>; no-op when unconnected; map 1317 → .cancelled; verify primary conn usable after cancel.
- Integration: browse windows (25-row seed), explain tree parse, create/drop db round-trip, mutation sum + rollback, cancel pg-sleep-equivalent `SELECT SLEEP(10)` aborted <5s.
- Commit: "feat(mysql-driver): browse, explain trees, transactional mutations, KILL QUERY cancel"

## Final acceptance (whole batch)

```bash
(cd Packages/NativQLKit && swift test) && \
(cd Packages/MySQLDriver && swift build) && \
NATIVQL_INTEGRATION=1 (cd Packages/MySQLDriver && swift test) && \
xcodebuild -project NativQL.xcodeproj -scheme NativQL test CODE_SIGNING_ALLOWED=NO
```
