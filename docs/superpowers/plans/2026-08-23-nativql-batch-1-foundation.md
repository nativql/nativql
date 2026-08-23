# NativQL Batch 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold the NativQL repo into a buildable macOS app + three-package star graph, with the complete pure-logic core (models, driver protocol, SQL utilities) unit-tested.

**Architecture:** XcodeGen generates `NativQL.xcodeproj` from `project.yml`. App target depends on local SPM package `NativQLKit` (pure logic, zero deps). Driver packages (`PostgresDriver`, `MySQLDriver`) are created as empty skeletons — their real implementations and external dependencies arrive in Batches 2–3. All code compiles in Swift 5 language mode to keep the contributor bar low.

**Tech Stack:** Swift 5.10 tools / Xcode 26, SwiftUI (macOS 14+), Swift Package Manager, XcodeGen, XCTest.

**Working directory for every task:** `/Users/sipamungkas/Documents/projects/macos/nativql`

---

## File Structure (locked by this plan)

```
project.yml                          # XcodeGen manifest
docker-compose.yml                   # postgres:16 + mysql:8 for integration tests
.github/workflows/ci.yml             # unit tests on push/PR
NativQL/                             # app target sources
  NativQLApp.swift
NativQLTests/
  SmokeTests.swift
Packages/NativQLKit/
  Package.swift
  Sources/NativQLKit/
    Models/DatabaseKind.swift
    Models/SSLMode.swift
    Models/ConnectionConfig.swift
    Models/TableRef.swift
    Models/TableInfo.swift
    Models/DatabaseInfo.swift
    Models/ColumnInfo.swift
    Models/SQLValue.swift
    Models/RowPage.swift
    Models/QueryResult.swift
    Models/SortSpec.swift
    Models/ExplainPlanNode.swift
    Models/MutationStatement.swift
    Drivers/DriverError.swift
    Drivers/DatabaseDriver.swift
    Utilities/SQLStatementSplitter.swift
    Utilities/ConnectionStringParser.swift
    Utilities/QueryTypeDetector.swift
    Utilities/EditabilityRules.swift
    Utilities/CSVExporter.swift
    Utilities/JSONExporter.swift
    Utilities/InsertStatementBuilder.swift
  Tests/NativQLKitTests/
    DatabaseKindTests.swift
    SSLModeTests.swift
    ConnectionStringParserTests.swift
    SQLStatementSplitterTests.swift
    QueryTypeDetectorTests.swift
    EditabilityRulesTests.swift
    CSVExporterTests.swift
    JSONExporterTests.swift
    InsertStatementBuilderTests.swift
Packages/PostgresDriver/
  Package.swift
  Sources/PostgresDriver/Placeholder.swift
Packages/MySQLDriver/
  Package.swift
  Sources/MySQLDriver/Placeholder.swift
```

---

### Task 1: Repo scaffolding + docker-compose

**Files:**
- Create: `docker-compose.yml`
- Create: `.gitkeep` files for directory structure

- [x] **Step 1: Create directories**

```bash
mkdir -p Packages/NativQLKit/Sources/NativQLKit/{Models,Drivers,Utilities}
mkdir -p Packages/NativQLKit/Tests/NativQLKitTests
mkdir -p Packages/PostgresDriver/Sources/PostgresDriver
mkdir -p Packages/MySQLDriver/Sources/MySQLDriver
mkdir -p NativQL NativQLTests .github/workflows
```

- [x] **Step 2: Write `docker-compose.yml`**

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: nativql
      POSTGRES_PASSWORD: nativql
      POSTGRES_DB: nativql_test
    ports:
      - "55432:5432"
  mysql:
    image: mysql:8
    environment:
      MYSQL_ROOT_PASSWORD: nativql
      MYSQL_USER: nativql
      MYSQL_PASSWORD: nativql
      MYSQL_DATABASE: nativql_test
    ports:
      - "53306:3306"
    command: --mysql_native_password=ON
```

Non-standard ports avoid colliding with locally installed servers.

- [x] **Step 3: Verify compose file parses**

Run: `docker compose config --quiet && echo OK`
Expected: `OK`

- [x] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "chore: scaffold batch 1 directories and docker-compose"
```

---

### Task 2: NativQLKit package + DatabaseKind + SSLMode

**Files:**
- Create: `Packages/NativQLKit/Package.swift`
- Create: `Packages/NativQLKit/Sources/NativQLKit/Models/DatabaseKind.swift`
- Create: `Packages/NativQLKit/Sources/NativQLKit/Models/SSLMode.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/DatabaseKindTests.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/SSLModeTests.swift`

- [x] **Step 1: Write failing tests**

`Packages/NativQLKit/Tests/NativQLKitTests/DatabaseKindTests.swift`:

```swift
import XCTest
@testable import NativQLKit

final class DatabaseKindTests: XCTestCase {
    func testDefaultPorts() {
        XCTAssertEqual(DatabaseKind.postgres.defaultPort, 5432)
        XCTAssertEqual(DatabaseKind.mysql.defaultPort, 3306)
    }

    func testDisplayNames() {
        XCTAssertEqual(DatabaseKind.postgres.displayName, "PostgreSQL")
        XCTAssertEqual(DatabaseKind.mysql.displayName, "MySQL")
    }
}
```

`Packages/NativQLKit/Tests/NativQLKitTests/SSLModeTests.swift`:

```swift
import XCTest
@testable import NativQLKit

final class SSLModeTests: XCTestCase {
    func testPostgresAvailableModes() {
        XCTAssertEqual(
            SSLMode.availableModes(for: .postgres),
            [.disable, .prefer, .require, .verifyFull]
        )
    }

    func testMySQLAvailableModes() {
        XCTAssertEqual(
            SSLMode.availableModes(for: .mysql),
            [.disable, .prefer, .require, .verifyCA, .verifyFull]
        )
    }
}
```

- [x] **Step 2: Write minimal implementation**

`Packages/NativQLKit/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NativQLKit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NativQLKit"),
        .testTarget(name: "NativQLKitTests", dependencies: ["NativQLKit"]),
    ]
)
```

`Packages/NativQLKit/Sources/NativQLKit/Models/DatabaseKind.swift`:

```swift
public enum DatabaseKind: String, Codable, Sendable, CaseIterable {
    case postgres
    case mysql

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: return 5432
        case .mysql: return 3306
        }
    }
}
```

`Packages/NativQLKit/Sources/NativQLKit/Models/SSLMode.swift`:

```swift
public enum SSLMode: String, Codable, Sendable, CaseIterable {
    case disable
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public static func availableModes(for kind: DatabaseKind) -> [SSLMode] {
        switch kind {
        case .postgres: return [.disable, .prefer, .require, .verifyFull]
        case .mysql: return [.disable, .prefer, .require, .verifyCA, .verifyFull]
        }
    }
}
```

Note: MySQL's `verify_identity` maps onto `verifyFull` at the driver layer (Batch 3); Kit keeps one canonical enum.

- [x] **Step 3: Run tests**

Run: `cd Packages/NativQLKit && swift test`
Expected: all tests PASS (4 assertions across 3 tests)

- [x] **Step 4: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add NativQLKit package with DatabaseKind and SSLMode"
```

---

### Task 3: Core models

**Files:**
- Create: `Sources/NativQLKit/Models/ConnectionConfig.swift`, `TableRef.swift`, `TableInfo.swift`, `DatabaseInfo.swift`, `ColumnInfo.swift`, `SQLValue.swift`, `RowPage.swift`, `QueryResult.swift`, `SortSpec.swift`, `ExplainPlanNode.swift`, `MutationStatement.swift`

(All paths under `Packages/NativQLKit/`; no behavior worth unit-testing yet beyond compilation and Sendable conformance.)

- [x] **Step 1: Write models**

`ConnectionConfig.swift`:

```swift
public struct ConnectionConfig: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var user: String
    public var password: String?
    public var database: String?
    public var sslMode: SSLMode
    public var colorLabel: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind,
        host: String,
        port: Int? = nil,
        user: String,
        password: String? = nil,
        database: String? = nil,
        sslMode: SSLMode = .prefer,
        colorLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.user = user
        self.password = password
        self.database = database
        self.sslMode = sslMode
        self.colorLabel = colorLabel
    }
}
```

`TableRef.swift`:

```swift
public struct TableRef: Hashable, Codable, Sendable {
    public var database: String
    public var schema: String?
    public var name: String

    public init(database: String, schema: String? = nil, name: String) {
        self.database = database
        self.schema = schema
        self.name = name
    }
}
```

`TableInfo.swift`:

```swift
public struct TableInfo: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case table
        case view
    }

    public var ref: TableRef
    public var kind: Kind
    /// Approximate row count from catalog stats; nil when unknown.
    public var estimatedRowCount: Int64?

    public init(ref: TableRef, kind: Kind = .table, estimatedRowCount: Int64? = nil) {
        self.ref = ref
        self.kind = kind
        self.estimatedRowCount = estimatedRowCount
    }
}
```

`DatabaseInfo.swift`:

```swift
public struct DatabaseInfo: Hashable, Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}
```

`ColumnInfo.swift`:

```swift
public struct ColumnInfo: Hashable, Codable, Sendable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    public var defaultValue: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
    }
}
```

`SQLValue.swift`:

```swift
import Foundation

public enum SQLValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    /// NUMERIC/DECIMAL kept as raw text to preserve precision; views format it.
    case decimal(String)
    case string(String)
    case date(Date)          // DATE only
    case time(TimeInterval)  // TIME as seconds since midnight
    case datetime(Date)      // TIMESTAMP / DATETIME
    case json(String)        // raw text; JSON viewer parses on demand
    case bytes(Data)
}
```

`RowPage.swift`:

```swift
public struct RowPage: Sendable {
    public var columns: [ColumnInfo]
    public var rows: [[SQLValue]]
    /// Server-side total estimate when cheaply available.
    public var totalCountEstimate: Int64?

    public init(columns: [ColumnInfo], rows: [[SQLValue]], totalCountEstimate: Int64? = nil) {
        self.columns = columns
        self.rows = rows
        self.totalCountEstimate = totalCountEstimate
    }
}
```

`QueryResult.swift`:

```swift
import Foundation

public struct QueryResult: Sendable {
    public var columns: [ColumnInfo]
    public var rows: [[SQLValue]]
    public var affectedRows: Int64?
    public var executionMilliseconds: Double
    public var statementType: StatementType

    public init(
        columns: [ColumnInfo],
        rows: [[SQLValue]],
        affectedRows: Int64? = nil,
        executionMilliseconds: Double,
        statementType: StatementType
    ) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.executionMilliseconds = executionMilliseconds
        self.statementType = statementType
    }
}
```

`SortSpec.swift`:

```swift
public struct SortSpec: Hashable, Sendable {
    public var columnName: String
    public var ascending: Bool

    public init(columnName: String, ascending: Bool = true) {
        self.columnName = columnName
        self.ascending = ascending
    }
}
```

`ExplainPlanNode.swift`:

```swift
public struct ExplainPlanNode: Sendable {
    public var operation: String
    public var detail: String?
    public var actualRows: Int64?
    public var actualTimeMilliseconds: Double?
    public var children: [ExplainPlanNode]

    public init(
        operation: String,
        detail: String? = nil,
        actualRows: Int64? = nil,
        actualTimeMilliseconds: Double? = nil,
        children: [ExplainPlanNode] = []
    ) {
        self.operation = operation
        self.detail = detail
        self.actualRows = actualRows
        self.actualTimeMilliseconds = actualTimeMilliseconds
        self.children = children
    }
}
```

`MutationStatement.swift`:

```swift
/// Built by the app's row-operations layer using ANSI `?` placeholders;
/// drivers bind `bindings` positionally and execute transactionally.
public struct MutationStatement: Sendable {
    public enum Kind: String, Sendable {
        case update, insert, delete
    }

    public var kind: Kind
    public var table: TableRef
    public var sql: String
    /// One binding list per affected row; drivers wrap all lists in one transaction.
    public var batches: [[SQLValue]]

    public init(kind: Kind, table: TableRef, sql: String, batches: [[SQLValue]]) {
        self.kind = kind
        self.table = table
        self.sql = sql
        self.batches = batches
    }
}
```

- [x] **Step 2: Build to verify compilation**

Run: `cd Packages/NativQLKit && swift build`
Expected: `Build complete!`

- [x] **Step 3: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add core domain models"
```

---

### Task 4: DriverError + DatabaseDriver protocol

**Files:**
- Create: `Packages/NativQLKit/Sources/NativQLKit/Drivers/DriverError.swift`
- Create: `Packages/NativQLKit/Sources/NativQLKit/Drivers/DatabaseDriver.swift`

- [x] **Step 1: Write error type**

`DriverError.swift`:

```swift
public enum DriverError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case tlsFailed(String)
    case queryFailed(String)
    case cancelled
    case timeout
    case introspectionFailed(String)
    case mutationFailed(String)
    case unsupportedFeature(String)

    public var message: String {
        switch self {
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .authenticationFailed(let m): return "Authentication failed: \(m)"
        case .tlsFailed(let m): return "TLS error: \(m)"
        case .queryFailed(let m): return m
        case .cancelled: return "Query cancelled"
        case .timeout: return "Query timed out"
        case .introspectionFailed(let m): return "Introspection failed: \(m)"
        case .mutationFailed(let m): return "Update failed: \(m)"
        case .unsupportedFeature(let m): return "Not supported: \(m)"
        }
    }
}
```

- [x] **Step 2: Write protocol**

`DatabaseDriver.swift`:

```swift
/// One implementation per engine (PostgresNIO / MySQLNIO).
/// All methods are async-throwing; implementers must be safe to hold long-term
/// per connected tab. Cancellation of the surrounding Swift Task must abort
/// in-flight network work where the protocol supports it.
public protocol DatabaseDriver: AnyObject, Sendable {
    var kind: DatabaseKind { get }

    // Lifecycle
    func connect(_ config: ConnectionConfig) async throws
    func disconnect() async
    func isConnected() async -> Bool

    // Queries
    /// Executes one or more statements sequentially. Multi-statement input
    /// returns the result of the LAST statement that produces rows, or an
    /// aggregate result otherwise. Must honor task cancellation.
    func execute(_ sql: String) async throws -> QueryResult
    func cancelRunningQuery() async

    // Introspection
    func listDatabases() async throws -> [DatabaseInfo]
    func listTables(database: String, schema: String?) async throws -> [TableInfo]
    func listColumns(_ table: TableRef) async throws -> [ColumnInfo]
    func primaryKey(of table: TableRef) async throws -> [String]?
    func tableDDL(_ table: TableRef) async throws -> String

    // Browsing & plans
    func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage
    func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode

    // Admin
    func createDatabase(named: String) async throws
    func dropDatabase(named: String) async throws

    // Mutations — statement built above the driver, bound and executed here.
    /// Returns total affected rows across all batches, executed in ONE transaction.
    func executeMutation(_ statement: MutationStatement) async throws -> Int64
}

extension DatabaseDriver {
    /// Default implementation backing the connection form's "Test" button;
    /// drivers may override with a cheaper ping.
    public func testConnection(_ config: ConnectionConfig) async throws {
        try await connect(config)
        await disconnect()
    }
}
```

(The spec's protocol sketch lists `testConnection` — provided here as a defaulted method so drivers only implement what they can optimize.)

- [x] **Step 3: Build**

Run: `cd Packages/NativQLKit && swift build && swift test`
Expected: build succeeds, existing tests still pass.

- [x] **Step 4: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add DatabaseDriver protocol and DriverError"
```

---

### Task 5: ConnectionStringParser (TDD)

**Files:**
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/ConnectionStringParser.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/ConnectionStringParserTests.swift`

- [x] **Step 1: Write failing tests**

```swift
import XCTest
@testable import NativQLKit

final class ConnectionStringParserTests: XCTestCase {
    func testParsesFullPostgresURL() throws {
        let config = try ConnectionStringParser.parse(
            "postgresql://bob:hunter2@db.example.com:6543/shop?sslmode=require"
        )
        XCTAssertEqual(config.kind, .postgres)
        XCTAssertEqual(config.user, "bob")
        XCTAssertEqual(config.password, "hunter2")
        XCTAssertEqual(config.host, "db.example.com")
        XCTAssertEqual(config.port, 6543)
        XCTAssertEqual(config.database, "shop")
        XCTAssertEqual(config.sslMode, .require)
    }

    func testPostgresSchemeAliasAndDefaults() throws {
        let config = try ConnectionStringParser.parse("postgres://alice@localhost/mydb")
        XCTAssertEqual(config.kind, .postgres)
        XCTAssertEqual(config.port, 5432)          // default filled in
        XCTAssertEqual(config.sslMode, .prefer)     // default when absent
        XCTAssertNil(config.password)
    }

    func testParsesMySQLURLWithEncodedPassword() throws {
        let config = try ConnectionStringParser.parse(
            "mysql://root:s3cret%40x@127.0.0.1:3307/app"
        )
        XCTAssertEqual(config.kind, .mysql)
        XCTAssertEqual(config.password, "s3cret@x")  // %40 decoded
        XCTAssertEqual(config.user, "root")
        XCTAssertEqual(config.port, 3307)
        XCTAssertEqual(config.database, "app")
    }

    func testRejectsUnknownScheme() {
        XCTAssertThrowsError(try ConnectionStringParser.parse("sqlite:///tmp/db.sqlite"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ConnectionStringParser.parse("not a url at all"))
    }
}
```

Note the `mysql://root@s3cret@...` case encodes `@` inside password as `%40` — fix the test string to `"mysql://root:s3cret%40x@127.0.0.1:3307/app"` expecting password `"s3cret@x"`. Use that corrected form in the final test file.

- [x] **Step 2: Run tests to verify failure**

Run: `cd Packages/NativQLKit && swift test --filter ConnectionStringParserTests`
Expected: FAIL — `ConnectionStringParser` undeclared.

- [x] **Step 3: Implement**

```swift
import Foundation

public enum ConnectionStringParserError: Error, Equatable {
    case invalidURL(String)
    case unsupportedScheme(String)
}

public enum ConnectionStringParser {
    public static func parse(_ raw: String) throws -> ConnectionConfig {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            throw ConnectionStringParserError.invalidURL(raw)
        }

        let kind: DatabaseKind
        switch scheme {
        case "postgres", "postgresql": kind = .postgres
        case "mysql": kind = .mysql
        default: throw ConnectionStringParserError.unsupportedScheme(scheme)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Percent-decoding handled via component accessors below.
        _ = components

        let user = url.user.map(decodePercentEscapes) ?? ""
        let password = url.password.map(decodePercentEscapes)
        let database = url.path.isEmpty ? nil : String(url.path.dropFirst())
        if database == nil || database!.isEmpty {
            // database optional in UI flow, but URLs normally include it
        }

        var config = ConnectionConfig(
            name: "\(user)@\(host)",
            kind: kind,
            host: host,
            port: url.port,
            user: user,
            password: password,
            database: database
        )

        if let queryItems = URLComponents(string: raw)?.queryItems {
            if let mode = queryItems.first(where: { $0.name == "sslmode" })?.value,
               let ssl = SSLMode(rawValue: mode) {
                config.sslMode = ssl
            }
        }
        return config
    }

    private static func decodePercentEscapes(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}
```

- [x] **Step 4: Run tests to verify pass**

Run: `cd Packages/NativQLKit && swift test --filter ConnectionStringParserTests`
Expected: PASS (5 tests)

- [x] **Step 5: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add ConnectionStringParser with tests"
```

---

### Task 6: SQLStatementSplitter (TDD)

**Files:**
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/SQLStatementSplitter.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/SQLStatementSplitterTests.swift`

- [x] **Step 1: Write failing tests**

```swift
import XCTest
@testable import NativQLKit

final class SQLStatementSplitterTests: XCTestCase {
    func testSplitsSimpleStatements() {
        let result = SQLStatementSplitter.split("SELECT 1; SELECT 2;")
        XCTAssertEqual(result, ["SELECT 1;", "SELECT 2;"])
    }

    func testKeepsSemicolonInsideStringLiteral() {
        let result = SQLStatementSplitter.split(#"SELECT 'a;b'; SELECT 2;"#)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], #"SELECT 'a;b';"#)
    }

    func testIgnoresSemicolonInLineComment() {
        let result = SQLStatementSplitter.split("""
        SELECT 1; -- comment; ignored
        SELECT 2;
        """)
        XCTAssertEqual(result.count, 2)
    }

    func testIgnoresSemicolonInBlockComment() {
        let result = SQLStatementSplitter.split("SELECT /* a;b */ 1; SELECT 2;")
        XCTAssertEqual(result.count, 2)
    }

    func testDollarQuotingPostgresFunctionBody() {
        let sql = """
        CREATE FUNCTION f() RETURNS void AS $$
        BEGIN
          RAISE NOTICE 'hi; there';
        END;
        $$ LANGUAGE plpgsql; SELECT 42;
        """
        let result = SQLStatementSplitter.split(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("RAISE NOTICE"))
    }

    func testDoubleQuotedIdentifiers() {
        let result = SQLStatementSplitter.split(#"SELECT "weird;name" FROM t; SELECT 2;"#)
        XCTAssertEqual(result.count, 2)
    }

    func testTrailingContentWithoutTerminator() {
        let result = SQLStatementSplitter.split("SELECT 1; SELECT 2")
        XCTAssertEqual(result, ["SELECT 1;", "SELECT 2"])
    }

    func testEmptyInputYieldsNoStatements() {
        XCTAssertEqual(SQLStatementSplitter.split("  ;;  \n"), [])
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `cd Packages/NativQLKit && swift test --filter SQLStatementSplitterTests`
Expected: FAIL — undeclared identifier.

- [x] **Step 3: Implement scanner**

Index-based scanner over `Array(sql)` — avoids iterator/peek pitfalls. Known accepted limitations (documented in header): nested dollar-tags sharing prefixes, and PostgreSQL treats backslash literally inside strings while this scanner honors `\'` escapes (MySQL-correct, near-harmless for PG).

```swift
/// Splits multi-statement SQL on top-level semicolons only, respecting
/// '...' strings, "..." identifiers, -- line comments, /* */ block comments
/// (with nesting), and $$ / $tag$ dollar-quoting (PostgreSQL).
///
/// Limitations: backslash escapes inside strings are honored (MySQL-style);
/// PostgreSQL standard-conforming strings are unaffected except for the
/// pathological trailing-backslash-before-quote case.
public enum SQLStatementSplitter {
    public static func split(_ sql: String) -> [String] {
        let chars = Array(sql)
        var statements: [String] = []
        var current = ""
        var i = 0

        func emit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { statements.append(trimmed) }
            current = ""
        }

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'":
                current.append(ch); i += 1
                i = scanQuoted(chars, from: i, terminator: "'", into: &current)
            case "\"":
                current.append(ch); i += 1
                i = scanQuoted(chars, from: i, terminator: "\"", into: &current)
            case "$":
                if let tag = dollarTag(at: chars, from: i) {
                    for c in tag { current.append(c) }
                    i += tag.count
                    i = scanDollarQuoted(chars, from: i, closingTag: tag, into: &current)
                } else {
                    current.append(ch); i += 1
                }
            case "-":
                if i + 1 < chars.count, chars[i + 1] == "-" {
                    while i < chars.count {
                        current.append(chars[i])
                        let atNewline = chars[i] == "\n"
                        i += 1
                        if atNewline { break }
                    }
                } else {
                    current.append(ch); i += 1
                }
            case "/":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    current.append("/"); current.append("*"); i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        current.append(chars[i])
                        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                            current.append("*"); depth += 1; i += 2
                        } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            current.append("/"); depth -= 1; i += 2
                        } else {
                            i += 1
                        }
                    }
                } else {
                    current.append(ch); i += 1
                }
            case ";":
                emit(); i += 1
            default:
                current.append(ch); i += 1
            }
        }
        emit()
        return statements
    }

    /// Scans until the closing quote (inclusive). Handles doubled quotes ('')
    /// and backslash escapes. Returns the index AFTER the closing quote,
    /// consuming no further characters (the caller must see any ';').
    static func scanQuoted(
        _ chars: [Character], from start: Int, terminator: Character, into out: inout String
    ) -> Int {
        var i = start
        while i < chars.count {
            let ch = chars[i]
            out.append(ch); i += 1
            if ch == "\\" {
                if i < chars.count { out.append(chars[i]); i += 1 }
            } else if ch == terminator {
                if i < chars.count, chars[i] == terminator {
                    out.append(chars[i]); i += 1   // doubled quote — keep scanning
                } else {
                    return i
                }
            }
        }
        return i
    }

    /// Returns "$$", "$tag$", or nil if this '$' doesn't start a dollar-quote.
    private static func dollarTag(at chars: [Character], from i: Int) -> String? {
        guard chars[i] == "$" else { return nil }
        var j = i + 1
        var tag = "$"
        while j < chars.count, chars[j] != "$" {
            let c = chars[j]
            guard c.isLetter || c.isNumber || c == "_" else { return nil }
            tag.append(c); j += 1
        }
        guard j < chars.count else { return nil }
        tag.append("$")
        return tag
    }

    private static func scanDollarQuoted(
        _ chars: [Character], from start: Int, closingTag: String, into out: inout String
    ) -> Int {
        let tag = Array(closingTag)
        var i = start
        while i < chars.count {
            if chars[i] == tag[0], i + tag.count <= chars.count,
               Array(chars[i..<i + tag.count]) == tag {
                for c in tag { out.append(c) }
                return i + tag.count
            }
            out.append(chars[i]); i += 1
        }
        return i
    }
}
```

- [x] **Step 4: Run tests**

Run: `cd Packages/NativQLKit && swift test --filter SQLStatementSplitterTests`
Expected: PASS (8 tests). If dollar-quoting fails, debug `dollarTag` state transitions before proceeding.

- [x] **Step 5: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add SQLStatementSplitter with quote/comment/dollar-quoting awareness"
```

---

### Task 7: QueryTypeDetector (TDD)

**Files:**
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/QueryTypeDetector.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/QueryTypeDetectorTests.swift`

- [x] **Step 1: Write failing tests**

```swift
import XCTest
@testable import NativQLKit

final class QueryTypeDetectorTests: XCTestCase {
    func testSelectDetection() {
        XCTAssertEqual(QueryTypeDetector.type(of: "SELECT * FROM users"), .select)
    }

    func testSkipsLeadingCommentsAndWhitespace() {
        XCTAssertEqual(QueryTypeDetector.type(of: "-- hi\n /* yo */ \n  select 1"), .select)
    }

    func testMutations() {
        XCTAssertEqual(QueryTypeDetector.type(of: "insert into t values (1)"), .insert)
        XCTAssertEqual(QueryTypeDetector.type(of: "UPDATE t SET a=1"), .update)
        XCTAssertEqual(QueryTypeDetector.type(of: "DELETE FROM t"), .delete)
    }

    func testDDLAndUtility() {
        XCTAssertEqual(QueryTypeDetector.type(of: "CREATE TABLE t(id int)"), .ddl)
        XCTAssertEqual(QueryTypeDetector.type(of: "DROP TABLE t"), .ddl)
        XCTAssertEqual(QueryTypeDetector.type(of: "ALTER TABLE t ADD c int"), .ddl)
        XCTAssertEqual(QueryTypeDetector.type(of: "EXPLAIN ANALYZE SELECT 1"), .explain)
    }

    func testTransactionStatements() {
        XCTAssertEqual(QueryTypeDetector.type(of: "BEGIN"), .transactionControl)
        XCTAssertEqual(QueryTypeDetector.type(of: "COMMIT"), .transactionControl)
        XCTAssertEqual(QueryTypeDetector.type(of: "ROLLBACK"), .transactionControl)
    }

    func testUnknownFallsBackToOther() {
        XCTAssertEqual(QueryTypeDetector.type(of: ""), .other)
        XCTAssertEqual(QueryTypeDetector.type(of: "VACUUM"), .other)
    }
}
```

- [x] **Step 2: Verify failure**

Run: `cd Packages/NativQLKit && swift test --filter QueryTypeDetectorTests`
Expected: FAIL — undeclared.

- [x] **Step 3: Implement**

```swift
public enum StatementType: String, Sendable {
    case select, insert, update, delete, ddl, explain, transactionControl, other
}

public enum QueryTypeDetector {
    public static func type(of sql: String) -> StatementType {
        let stripped = stripComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = stripped
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ";" })
            .first?.lowercased() else { return .other }
        switch firstWord {
        case "select", "with", "table", "values": return .select
        case "insert": return .insert
        case "update": return .update
        case "delete": return .delete
        case "explain": return .explain
        case "create", "alter", "drop", "truncate", "comment": return .ddl
        case "begin", "start", "commit", "rollback", "savepoint", "release",
             "set", "show", "use":
            return .transactionControl
        default: return .other
        }
    }

    /// Removes -- and /* */ comments while preserving string literals.
    /// Reuses SQLStatementSplitter.scanQuoted so both stay consistent.
    static func stripComments(_ sql: String) -> String {
        let chars = Array(sql)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'":
                out.append(ch); i += 1
                i = SQLStatementSplitter.scanQuoted(chars, from: i, terminator: "'", into: &out)
            case "\"":
                out.append(ch); i += 1
                i = SQLStatementSplitter.scanQuoted(chars, from: i, terminator: "\"", into: &out)
            case "-":
                if i + 1 < chars.count, chars[i + 1] == "-" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    if i < chars.count { out.append("\n"); i += 1 }
                } else { out.append(ch); i += 1 }
            case "/":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                            depth += 1; i += 2
                        } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            depth -= 1; i += 2
                        } else { i += 1 }
                    }
                    out.append(" ")
                } else { out.append(ch); i += 1 }
            default:
                out.append(ch); i += 1
            }
        }
        return out
    }
}
```

(`SET`/`SHOW`/`USE` classified as transactionControl keeps grid read-only logic simple; revisit in Batch 6 if needed.)

- [x] **Step 4: Run tests**

Run: `cd Packages/NativQLKit && swift test --filter QueryTypeDetectorTests`
Expected: PASS (6 tests)

- [x] **Step 5: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add QueryTypeDetector with comment stripping"
```

---

### Task 8: EditabilityRules (TDD)

**Files:**
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/EditabilityRules.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/EditabilityRulesTests.swift`

- [x] **Step 1: Write failing tests**

```swift
import XCTest
@testable import NativQLKit

final class EditabilityRulesTests: XCTestCase {
    func testSimpleBrowsedTableIsEditable() {
        let decision = EditabilityRules.evaluate(
            source: .tableBrowse, hasPrimaryKey: true
        )
        XCTAssertEqual(decision, .editable)
    }

    func testBrowseWithoutPKIsLocked() {
        let decision = EditabilityRules.evaluate(source: .tableBrowse, hasPrimaryKey: false)
        XCTAssertEqual(
            decision,
            .readOnly(reason: "Table has no primary key, so rows can't be updated safely.")
        )
    }

    func testJoinedQueryIsLocked() {
        let decision = EditabilityRules.evaluate(
            source: .query(singleTable: false, usesAggregation: true),
            hasPrimaryKey: true
        )
        XCTAssertEqual(
            decision,
            .readOnly(reason: "Only single-table queries without joins or aggregation are editable.")
        )
    }

    func testSingleTablePlainQueryIsEditable() {
        let decision = EditabilityRules.evaluate(
            source: .query(singleTable: true, usesAggregation: false),
            hasPrimaryKey: true
        )
        XCTAssertEqual(decision, .editable)
    }

    func testAggregateQueryIsLocked() {
        let decision = EditabilityRules.evaluate(
            source: .query(singleTable: true, usesAggregation: true),
            hasPrimaryKey: true
        )
        XCTAssertTrue(isReadOnly(decision))
    }

    private func isReadOnly(_ d: EditabilityDecision) -> Bool {
        if case .readOnly = d { return true }
        return false
    }
}
```

- [x] **Step 2: Verify failure**

Run: `cd Packages/NativQLKit && swift test --filter EditabilityRulesTests`
Expected: FAIL — undeclared.

- [x] **Step 3: Implement**

```swift
public enum EditabilitySource: Sendable {
    case tableBrowse
    case query(singleTable: Bool, usesAggregation: Bool)
}

public enum EditabilityDecision: Equatable, Sendable {
    case editable
    case readOnly(reason: String)
}

public enum EditabilityRules {
    public static func evaluate(
        source: EditabilitySource,
        hasPrimaryKey: Bool
    ) -> EditabilityDecision {
        switch source {
        case .tableBrowse:
            return hasPrimaryKey
                ? .editable
                : .readOnly(reason: "Table has no primary key, so rows can't be updated safely.")
        case .query(let singleTable, let usesAggregation):
            guard singleTable, !usesAggregation else {
                return .readOnly(
                    reason: "Only single-table queries without joins or aggregation are editable."
                )
            }
            return hasPrimaryKey
                ? .editable
                : .readOnly(reason: "Underlying table has no primary key.")
        }
    }
}
```

(The caller in Batch 6 computes `singleTable`/`usesAggregation` heuristics — e.g., regex for `JOIN`, `GROUP BY`, aggregate functions — over the detected single statement. Rules stay pure here.)

- [x] **Step 4: Run tests**

Run: `cd Packages/NativQLKit && swift test --filter EditabilityRulesTests`
Expected: PASS (5 tests)

- [x] **Step 5: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add EditabilityRules"
```

---

### Task 9: Exporters (TDD)

**Files:**
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/CSVExporter.swift`
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/JSONExporter.swift`
- Create: `Packages/NativQLKit/Sources/NativQLKit/Utilities/InsertStatementBuilder.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/CSVExporterTests.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/JSONExporterTests.swift`
- Test: `Packages/NativQLKit/Tests/NativQLKitTests/InsertStatementBuilderTests.swift`

- [x] **Step 1: Write failing CSV tests**

```swift
import XCTest
import Foundation
@testable import NativQLKit

final class CSVExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", dataType: "int4"),
        ColumnInfo(name: "name", dataType: "text"),
        ColumnInfo(name: "note", dataType: "text"),
    ]

    func testBasicExport() {
        let csv = CSVExporter.export(
            columns: columns,
            rows: [[.int(1), .string("ada"), .null]]
        )
        XCTAssertEqual(csv, "id,name,note\n1,ada,\n")
    }

    func testQuotesValuesWithCommasQuotesAndNewlines() {
        let csv = CSVExporter.export(
            columns: columns,
            rows: [[.int(2), .string("say \"hi\", ok"), .string("line1\nline2")]]
        )
        XCTAssertEqual(csv, "id,name,note\n2,\"say \"\"hi\"\", ok\",\"line1\nline2\"\n")
    }

    func testBoolRendering() {
        let csv = CSVExporter.export(
            columns: [ColumnInfo(name: "flag", dataType: "bool")],
            rows: [[.bool(true)], [.bool(false)]]
        )
        XCTAssertEqual(csv, "flag\ntrue\nfalse\n")
    }
}
```

- [x] **Step 2: Implement CSVExporter**

```swift
import Foundation

public enum CSVExporter {
    public static func export(columns: [ColumnInfo], rows: [[SQLValue]]) -> String {
        var lines = [columns.map(\.name).map(escape).joined(separator: ",")]
        for row in rows {
            lines.append(row.map(render).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ value: SQLValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .decimal(let s): return s
        case .string(let s): return s
        case .date(let date):
            return Self.dateFormatter.string(from: date)
        case .time(let seconds):
            return Self.timeFormatter.string(from: seconds)
        case .datetime(let date):
            return Self.datetimeFormatter.string(from: date)
        case .json(let s): return s
        case .bytes(let data): return data.base64EncodedString()
        }
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let datetimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.zeroFormattingBehavior = .pad
        return f
    }()
}
```

- [x] **Step 3: Write failing JSON + INSERT tests and implementations**

JSONExporter tests:

```swift
import XCTest
import Foundation
@testable import NativQLKit

final class JSONExporterTests: XCTestCase {
    func testArrayOfObjectsWithNullsAndBooleans() throws {
        let json = JSONExporter.export(
            columns: [ColumnInfo(name: "id", dataType: "int4"),
                      ColumnInfo(name: "active", dataType: "bool"),
                      ColumnInfo(name: "note", dataType: "text")],
            rows: [[.int(1), .bool(true), .null]]
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["id"] as? Int, 1)
        XCTAssertEqual(parsed[0]["active"] as? Bool, true)
        XCTAssertNil(parsed[0]["note"])
    }
}
```

JSONExporter implementation (serialize via JSONSerialization-safe dictionary construction):

```swift
import Foundation

public enum JSONExporter {
    public static func export(columns: [ColumnInfo], rows: [[SQLValue]]) -> String {
        var objects: [[String: Any]] = []
        objects.reserveCapacity(rows.count)
        for row in rows {
            var obj: [String: Any] = [:]
            for (i, col) in columns.enumerated() where i < row.count {
                obj[col.name] = jsonObject(row[i])
            }
            objects.append(obj)
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func jsonObject(_ value: SQLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .decimal(let s): return s
        case .string(let s): return s
        case .date(let d): return CSVExporter.dateFormatter.string(from: d)
        case .time(let s): return CSVExporter.timeFormatter.string(from: s) ?? ""
        case .datetime(let d): return ISO8601DateFormatter().string(from: d)
        case .json(let raw):
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                return parsed
            }
            return raw
        case .bytes(let data): return data.base64EncodedString()
        }
    }
}
```

InsertStatementBuilder tests:

```swift
import XCTest
@testable import NativQLKit

final class InsertStatementBuilderTests: XCTestCase {
    func testBuildsParameterizedInsertPerRow() {
        let ref = TableRef(database: "shop", schema: "public", name: "users")
        let columns = [ColumnInfo(name: "name", dataType: "text"),
                       ColumnInfo(name: "age", dataType: "int4")]
        let result = InsertStatementBuilder.build(
            table: ref,
            columns: columns,
            rows: [[.string("ada"), .int(36)], [.string("grace"), .null]]
        )
        XCTAssertEqual(
            result.sql,
            "INSERT INTO \"public\".\"users\" (\"name\", \"age\") VALUES (?, ?);"
        )
        XCTAssertEqual(result.batches.count, 2)
        XCTAssertEqual(result.batches[0], [.string("ada"), .int(36)])
        XCTAssertEqual(result.batches[1], [.string("grace"), .null])
    }
}
```

Implementation — note `batches` store plain values; represent ints as `.int`:

```swift
public enum InsertStatementBuilder {
    public static func build(
        table: TableRef,
        columns: [ColumnInfo],
        rows: [[SQLValue]]
    ) -> MutationStatement {
        let qualified = quote(table.schema) + "." + quote(table.name)
        let columnList = columns.map { quote($0.name) }.joined(separator: ", ")
        let placeholders = "(" + Array(repeating: "?", count: columns.count).joined(separator: ", ") + ")"
        let sql = "INSERT INTO \(qualified) (\(columnList)) VALUES \(placeholders);"

        let batches = rows.map { row in
            (0..<columns.count).map { idx in idx < row.count ? row[idx] : SQLValue.null }
        }
        return MutationStatement(kind: .insert, table: table, sql: sql, batches: batches)
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
```

MySQL quoting differs (backticks) — driver-level translation lands in Batch 3; Kit emits PG-style double quotes as canonical and documents it on the type.

- [x] **Step 4: Run all exporter tests**

Run: `cd Packages/NativQLKit && swift test --filter "CSVExporter|JSONExporter|InsertStatement"`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add Packages/NativQLKit
git commit -m "feat(kit): add CSV/JSON exporters and INSERT statement builder"
```

---

### Task 10: Driver package skeletons

**Files:**
- Create: `Packages/PostgresDriver/Package.swift`, `Sources/PostgresDriver/Placeholder.swift`
- Create: `Packages/MySQLDriver/Package.swift`, `Sources/MySQLDriver/Placeholder.swift`

- [x] **Step 1: PostgresDriver skeleton**

`Packages/PostgresDriver/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PostgresDriver",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PostgresDriver", targets: ["PostgresDriver"])],
    dependencies: [
        .package(path: "../NativQLKit"),
    ],
    targets: [
        .target(name: "PostgresDriver", dependencies: [
            .product(name: "NativQLKit", package: "NativQLKit"),
        ]),
    ]
)
```

`Packages/PostgresDriver/Sources/PostgresDriver/Placeholder.swift`:

```swift
// PostgresNIO-backed DatabaseDriver implementation arrives in Batch 2.
// This placeholder exists so the star dependency graph resolves today.
public enum PostgresDriverInfo {
    public static let version = "0.1.0-batch1"
}
```

- [x] **Step 2: MySQLDriver skeleton** — identical shape, name `MySQLDriver`, placeholder `MySQLDriverInfo`.

- [x] **Step 3: Verify both build**

Run:
```bash
(cd Packages/PostgresDriver && swift build) && (cd Packages/MySQLDriver && swift build)
```
Expected: both `Build complete!`

- [x] **Step 4: Commit**

```bash
git add Packages
git commit -m "chore: add PostgresDriver and MySQLDriver package skeletons"
```

---

### Task 11: App target via XcodeGen

**Files:**
- Create: `project.yml`
- Create: `NativQL/NativQLApp.swift`

- [x] **Step 1: Write project.yml**

```yaml
name: NativQL
options:
  bundleIdPrefix: dev.nativql
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  NativQLKit:
    path: Packages/NativQLKit
  PostgresDriver:
    path: Packages/PostgresDriver
  MySQLDriver:
    path: Packages/MySQLDriver
settings:
  base:
    SWIFT_VERSION: "5.10"
targets:
  NativQL:
    type: application
    platform: macOS
    sources:
      - NativQL
    dependencies:
      - package: NativQLKit
      - package: PostgresDriver
      - package: MySQLDriver
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.nativql.app
        MARKETING_VERSION: "0.1.0"
        GENERATE_INFOPLIST_FILE: true
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: true
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.developer-tools
  NativQLTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - NativQLTests
    dependencies:
      - target: NativQL
schemes:
  NativQL:
    build:
      targets:
        NativQL: all
        NativQLTests: [test]
    test:
      targets:
        - NativQLTests
```

- [x] **Step 2: Write app entry point**

`NativQL/NativQLApp.swift`:

```swift
import SwiftUI

@main
struct NativQLApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    var body: some View {
        Text("NativQL")
            .font(.largeTitle)
    }
}
```

- [x] **Step 3: Add placeholder test**

`NativQLTests/SmokeTests.swift`:

```swift
import XCTest
@testable import NativQLKit

final class SmokeTests: XCTestCase {
    func testAppLinksKit() {
        XCTAssertEqual(DatabaseKind.postgres.displayName, "PostgreSQL")
    }
}
```

- [x] **Step 4: Generate project and build**

Run:
```bash
xcodegen generate
xcodebuild -project NativQL.xcodeproj -scheme NativQL -configuration Debug build CODE_SIGNING_ALLOWED=NO | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [x] **Step 5: Run app test scheme**

Run:
```bash
xcodebuild -project NativQL.xcodeproj -scheme NativQL test CODE_SIGNING_ALLOWED=NO | tail -3
```
Expected: `** TEST SUCCEEDED **` (1 test executed)

- [x] **Step 6: Commit generated project too**

Committing `NativQL.xcodeproj` keeps clone-and-open working for contributors without XcodeGen:

```bash
git add project.yml NativQL NativQLTests NativQL.xcodeproj
git commit -m "feat(app): scaffold macOS app target via XcodeGen"
```

---

### Task 12: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [x] **Step 1: Write workflow**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  kit-tests:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: NativQLKit unit tests
        run: cd Packages/NativQLKit && swift test
  app-build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build app
        run: |
          xcodebuild -project NativQL.xcodeproj -scheme NativQL \
            -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

- [x] **Step 2: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run Kit unit tests and app build on push/PR"
git push origin main
```

Then open https://github.com/nativql/nativql/actions and confirm both jobs go green (first run takes ~5 min).

---

### Task 13: Batch 1 acceptance

- [x] **Step 1: Full local verification**

```bash
(cd Packages/NativQLKit && swift test) && \
(cd Packages/PostgresDriver && swift build) && \
(cd Packages/MySQLDriver && swift build) && \
xcodebuild -project NativQL.xcodeproj -scheme NativQL test CODE_SIGNING_ALLOWED=NO | tail -1
```
Expected: all green, `** TEST SUCCEEDED **`

- [x] **Step 2: Launch app manually once**

Run: `open ~/Library/Developer/Xcode/DerivedData/NativQL-*/Build/Products/Debug/NativQL.app`
Expected: window titled NativQL shows "NativQL". Quit it.

- [x] **Step 3: Push**

```bash
git push origin main
```

Batch 1 done → write/review Batch 2 plan (PostgreSQL driver).
