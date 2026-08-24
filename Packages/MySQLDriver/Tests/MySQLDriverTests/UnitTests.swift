import XCTest
import NativQLKit
import NIOCore
import NIOSSL
import MySQLNIO
@testable import MySQLDriver

/// Error classification — pure decisions, no connection required.
final class ErrorClassificationUnitTests: XCTestCase {
    /// Builds a real server ERR packet by decoding wire bytes, so the
    /// structured-code branch of `classify` is exercised end to end.
    private func makeServerError(code: UInt16, message: String) -> MySQLError {
        var payload = ByteBufferAllocator().buffer(capacity: 64)
        payload.writeInteger(UInt8(0xFF))
        payload.writeInteger(code, endianness: .little)
        payload.writeString("#28000")
        payload.writeString(message)
        var packet = MySQLPacket(payload: payload)
        let decoded = try! MySQLProtocol.ERR_Packet.decode(
            from: &packet,
            capabilities: [.CLIENT_PROTOCOL_41]
        )
        return MySQLError.server(decoded)
    }

    func testServerAccessDeniedMapsToAuthenticationFailed() {
        let error = makeServerError(
            code: 1045,
            message: "Access denied for user 'nativql'@'localhost' (using password: YES)"
        )
        guard case .authenticationFailed(let message) = MySQLDriver.classify(error) else {
            return XCTFail("expected authenticationFailed, got \(MySQLDriver.classify(error))")
        }
        XCTAssertTrue(message.contains("nativql"), "server text must be surfaced: \(message)")
    }

    func testOtherServerCodeMapsToConnectionFailed() {
        // 1049 = ER_BAD_DB_ERROR ("Unknown database"), a connect-time config issue.
        let error = makeServerError(code: 1049, message: "Unknown database 'nope'")
        guard case .connectionFailed(let message) = MySQLDriver.classify(error) else {
            return XCTFail("expected connectionFailed, got \(MySQLDriver.classify(error))")
        }
        XCTAssertEqual(message, "Unknown database 'nope'")
    }

    func testCancellationMapsToCancelled() {
        XCTAssertEqual(MySQLDriver.classify(CancellationError()), DriverError.cancelled)
    }

    func testSecureConnectionRequiredMapsToTLSFailed() {
        // The remedy for this auth-time failure is enabling TLS.
        guard case .tlsFailed = MySQLDriver.classify(MySQLError.secureConnectionRequired) else {
            return XCTFail("expected tlsFailed")
        }
    }

    func testTLSKeywordSniffing() {
        let error = StringError("NIOSSL certificate verification failed")
        guard case .tlsFailed = MySQLDriver.classify(error) else {
            return XCTFail("expected tlsFailed")
        }
    }

    func testAuthKeywordSniffingForNonServerErrors() {
        let error = StringError("Unsupported auth plugin name: sha256_password")
        guard case .authenticationFailed = MySQLDriver.classify(error) else {
            return XCTFail("expected authenticationFailed")
        }
    }

    func testEverythingElseMapsToConnectionFailed() {
        let error = StringError("Connection refused (errno 61)")
        guard case .connectionFailed(let message) = MySQLDriver.classify(error) else {
            return XCTFail("expected connectionFailed")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// Minimal labeled error for sniffing-path tests.
    private struct StringError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// Execution-phase error mapping (Batch 3 Task D cancel path).
final class ExecutionErrorMappingUnitTests: XCTestCase {
    /// Builds a real server ERR packet by decoding wire bytes.
    private func makeServerError(code: UInt16, message: String) -> MySQLError {
        var payload = ByteBufferAllocator().buffer(capacity: 64)
        payload.writeInteger(UInt8(0xFF))
        payload.writeInteger(code, endianness: .little)
        payload.writeString("#HY000")
        payload.writeString(message)
        var packet = MySQLPacket(payload: payload)
        let decoded = try! MySQLProtocol.ERR_Packet.decode(
            from: &packet,
            capabilities: [.CLIENT_PROTOCOL_41]
        )
        return MySQLError.server(decoded)
    }

    func testServerQueryInterruptedMapsToCancelled() {
        // ER_QUERY_INTERRUPTED (1317): what KILL QUERY surfaces on the
        // primary connection for row-streaming statements.
        let error = makeServerError(code: 1317, message: "Query execution was interrupted")
        XCTAssertEqual(MySQLDriver.mapExecutionError(error), .cancelled)
    }

    func testCancellationErrorMapsToCancelled() {
        XCTAssertEqual(MySQLDriver.mapExecutionError(CancellationError()), .cancelled)
    }

    func testOtherServerErrorsMapToQueryFailed() {
        let error = makeServerError(code: 1146, message: "Table 'x.no' doesn't exist")
        guard case .queryFailed(let message) = MySQLDriver.mapExecutionError(error) else {
            return XCTFail("expected queryFailed")
        }
        XCTAssertEqual(message, "Table 'x.no' doesn't exist")
    }

    func testDriverErrorsPassThroughUnchanged() {
        let original = DriverError.mutationFailed("boom")
        XCTAssertEqual(MySQLDriver.mapExecutionError(original), original)
    }
}

/// SSLMode → NIOSSL configuration mapping shapes.
final class TLSMappingUnitTests: XCTestCase {
    func testDisableProducesNilConfiguration() throws {
        XCTAssertNil(TLSConfiguration.makeMySQLClient(for: .disable),
                     "nil is the only way to keep MySQLNIO on plaintext")
    }

    func testPreferAndRequireSkipValidation() throws {
        for mode in [SSLMode.prefer, .require] {
            let tls = try XCTUnwrap(TLSConfiguration.makeMySQLClient(for: mode))
            XCTAssertEqual(tls.certificateVerification, .none, "\(mode) must not validate certificates")
        }
    }

    func testVerifyCAChecksChainButNotHostname() throws {
        let tls = try XCTUnwrap(TLSConfiguration.makeMySQLClient(for: .verifyCA))
        XCTAssertEqual(tls.certificateVerification, .noHostnameVerification)
    }

    func testVerifyFullChecksChainAndHostname() throws {
        let tls = try XCTUnwrap(TLSConfiguration.makeMySQLClient(for: .verifyFull))
        XCTAssertEqual(tls.certificateVerification, .fullVerification)
    }

    func testEndpointEnablesServerNameOnlyWhenTLSRequested() throws {
        var config = makeConfig()
        config.sslMode = .disable
        XCTAssertNil(MySQLEndpoint.make(from: config).serverName)

        config.sslMode = .verifyFull
        let endpoint = MySQLEndpoint.make(from: config)
        XCTAssertEqual(endpoint.serverName, "127.0.0.1", "SNI/hostname check needs the host")
        XCTAssertNotNil(endpoint.tlsConfiguration)
    }

    func testEndpointCarriesCredentialAndTargetFields() throws {
        let endpoint = MySQLEndpoint.make(from: makeConfig())
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 53306)
        XCTAssertEqual(endpoint.username, "nativql")
        XCTAssertEqual(endpoint.password, "nativql")
        XCTAssertEqual(endpoint.database, "nativql_test")

        let address = try endpoint.socketAddress
        XCTAssertEqual(address.port, 53306)
    }

    private func makeConfig() -> ConnectionConfig {
        ConnectionConfig(
            name: "unit",
            kind: .mysql,
            host: "127.0.0.1",
            port: 53306,
            user: "nativql",
            password: "nativql",
            database: "nativql_test"
        )
    }
}

// MARK: - SQLValueMapper unit tests (Batch 3 Task B)

final class SQLValueMapperUnitTests: XCTestCase {
    func testNullCellMapsToNull() {
        XCTAssertTrue(SQLValueMapper.map(.null).isNull)
        let empty = MySQLData(type: .varString, format: .text, buffer: nil)
        XCTAssertTrue(SQLValueMapper.map(empty).isNull)
    }

    func testSignedIntegerTypesMapToInt() {
        let data = MySQLData(int: 42)
        XCTAssertEqual(SQLValueMapper.map(data), .int(42))
    }

    func testUnsignedBigIntBeyondInt64FallsBackToString() {
        // 2^63 (9_223_372_036_854_775_808) exceeds Int64.max
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(UInt64(9_223_372_036_854_775_808), endianness: .little)
        let data = MySQLData(type: .longlong, format: .binary, buffer: buffer, isUnsigned: true)
        XCTAssertEqual(SQLValueMapper.map(data), .string("9223372036854775808"))
    }

    func testUnsignedSmallIntsMapToInt() {
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeInteger(UInt32(3_000_000_000), endianness: .little)
        let data = MySQLData(type: .long, format: .binary, buffer: buffer, isUnsigned: true)
        XCTAssertEqual(SQLValueMapper.map(data), .int(3_000_000_000))
    }

    func testDecimalKeepsRawTextWithScale() {
        let data = MySQLData(string: "1234.5670")
        XCTAssertEqual(data.type, .varString) // string-init guard
        let decimal = MySQLData(type: .newdecimal, format: .text, buffer: {
            var b = ByteBufferAllocator().buffer(capacity: 16)
            b.writeString("1234.5670")
            return b
        }())
        XCTAssertEqual(SQLValueMapper.map(decimal), .decimal("1234.5670"))
    }

    func testDoubleAndFloatMap() {
        XCTAssertEqual(SQLValueMapper.map(MySQLData(double: 1.5)), .double(1.5))
        XCTAssertEqual(SQLValueMapper.map(MySQLData(float: 2.5)), .double(2.5))
    }

    func testJSONMapsToRawText() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.writeString(#"{"a": 1}"#)
        let data = MySQLData(type: .json, format: .binary, buffer: buffer)
        XCTAssertEqual(SQLValueMapper.map(data), .json(#"{"a": 1}"#))
    }

    func testBlobFamilyMapsToBytes() {
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        let data = MySQLData(type: .blob, format: .binary, buffer: buffer)
        XCTAssertEqual(SQLValueMapper.map(data, isBinaryCharset: true), .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }

    func testTimeTextParsing() {
        XCTAssertEqual(SQLValueMapper.parseTimeString("13:45:30"), 49530)
        XCTAssertEqual(SQLValueMapper.parseTimeString("-01:00:05"), -3605)
        XCTAssertNil(SQLValueMapper.parseTimeString("garbage"))
        XCTAssertEqual(SQLValueMapper.timeBindingString(49530), "13:45:30")
        XCTAssertEqual(SQLValueMapper.timeBindingString(-3605), "-01:00:05")
        XCTAssertEqual(SQLValueMapper.timeBindingString(90061), "25:01:01")
    }

    func testReverseBindingRoundTripsPrimitives() {
        XCTAssertEqual(SQLValueMapper.bindable(.null).type, .null)
        XCTAssertEqual(SQLValueMapper.bindable(.bool(true)).bool, true)
        XCTAssertEqual(SQLValueMapper.bindable(.int(7)).int, 7)
        XCTAssertEqual(SQLValueMapper.bindable(.double(1.25)).double, 1.25)
        XCTAssertEqual(SQLValueMapper.bindable(.string("hi")).string, "hi")
        XCTAssertEqual(SQLValueMapper.bindable(.decimal("1.50")).string, "1.50")
        if case .bytes(let data) = SQLValueMapper.map(SQLValueMapper.bindable(.bytes(Data([1, 2, 3]))), isBinaryCharset: true) {
            XCTAssertEqual(data, Data([1, 2, 3]))
        } else {
            XCTFail("expected bytes round trip")
        }
    }

    func testTypeNameMapping() {
        XCTAssertEqual(SQLValueMapper.typeName(.longlong), "bigint")
        XCTAssertEqual(SQLValueMapper.typeName(.newdecimal), "decimal")
        XCTAssertEqual(SQLValueMapper.typeName(.json), "json")
        XCTAssertEqual(SQLValueMapper.typeName(.datetime), "datetime")
    }
}

extension SQLValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - IdentifierQuoting unit tests (Batch 3 Task C)

/// Pure backtick quoting — no connection required.
final class IdentifierQuotingUnitTests: XCTestCase {
    func testQuotesPlainIdentifier() {
        XCTAssertEqual(IdentifierQuoting.quote("users"), "`users`")
        XCTAssertEqual(IdentifierQuoting.quote("b3c_test"), "`b3c_test`")
    }

    func testDoublesEmbeddedBackticks() {
        XCTAssertEqual(IdentifierQuoting.quote("we`ird"), "`we``ird`")
        XCTAssertEqual(IdentifierQuoting.quote("`"), "````")
    }

    func testPreservesCaseSpacesAndSpecials() {
        XCTAssertEqual(IdentifierQuoting.quote("MixedCase"), "`MixedCase`")
        XCTAssertEqual(IdentifierQuoting.quote("with space"), "`with space`")
        XCTAssertEqual(IdentifierQuoting.quote("order"), "`order`")
        XCTAssertEqual(IdentifierQuoting.quote(""), "``")
        // Dots must stay inside one quoted identifier, not split into parts.
        XCTAssertEqual(IdentifierQuoting.quote("db.tbl"), "`db.tbl`")
    }
}

// MARK: - ExplainParser unit tests (Batch 3 Task D)

/// Parses fixtures captured VERBATIM from the live MySQL 8.4 server
/// (`EXPLAIN ANALYZE … \G`, dockerized compose service) — no connection
/// required.
final class ExplainParserUnitTests: XCTestCase {
    /// Real output: join plan with cost groups, fractional per-loop row
    /// averages, and a backtick-bearing Sort label.
    private static let analyzedJoinFixture = """
    -> Limit: 10 row(s)  (cost=23.8 rows=10) (actual time=0.0859..0.0998 rows=10 loops=1)
        -> Nested loop inner join  (cost=23.8 rows=20) (actual time=0.0855..0.0988 rows=10 loops=1)
            -> Sort: u.`name`  (cost=2.75 rows=25) (actual time=0.0574..0.0577 rows=7 loops=1)
                -> Table scan on u  (cost=2.75 rows=25) (actual time=0.0345..0.0387 rows=25 loops=1)
            -> Filter: (o.amount > 20.00)  (cost=0.603 rows=0.8) (actual time=0.00521..0.00553 rows=1.43 loops=7)
                -> Index lookup on o using idx_user (user_id=u.id)  (cost=0.603 rows=2.4) (actual time=0.00473..0.00499 rows=2.14 loops=7)
    """

    /// Real output: a branch that never ran reports "(never executed)" and
    /// carries scientific-notation timings on other nodes.
    private static let neverExecutedFixture = """
    -> Limit: 10 row(s)  (actual time=0.0593..0.0593 rows=0 loops=1)
        -> Sort: u.`name`, limit input to 10 row(s) per chunk  (actual time=0.0588..0.0588 rows=0 loops=1)
            -> Stream results  (cost=0.7 rows=1) (actual time=0.0328..0.0328 rows=0 loops=1)
                -> Nested loop inner join  (cost=0.7 rows=1) (actual time=0.0225..0.0225 rows=0 loops=1)
                    -> Filter: ((o.amount > 20.00) and (o.user_id is not null))  (cost=0.35 rows=1) (actual time=0.022..0.022 rows=0 loops=1)
                        -> Table scan on o  (cost=0.35 rows=1) (actual time=0.00713..0.00713 rows=0 loops=1)
                    -> Single-row index lookup on u using PRIMARY (id=o.user_id)  (cost=0.35 rows=1) (never executed)
    """

    /// Real output: `EXPLAIN FORMAT=TREE` — same shape, no actual groups.
    private static let plainTreeFixture = """
    -> Filter: (b3_probe_users.`name` = 'u3')  (cost=2.75 rows=2.5)
        -> Table scan on b3_probe_users  (cost=2.75 rows=25)
    """

    func testParsesRootOperationCostAndActuals() throws {
        let plan = try ExplainParser.parse(Self.analyzedJoinFixture)
        XCTAssertEqual(plan.operation, "Limit: 10 row(s)")
        XCTAssertEqual(plan.actualRows, 10)
        XCTAssertEqual(plan.actualTimeMilliseconds!, 0.0998, accuracy: 1e-12)
        XCTAssertEqual(plan.detail, "cost=23.8 rows=10")
    }

    func testParsesChildrenByIndentation() throws {
        let plan = try ExplainParser.parse(Self.analyzedJoinFixture)
        XCTAssertEqual(plan.children.count, 1, "root has one child chain")

        let join = plan.children[0]
        XCTAssertEqual(join.operation, "Nested loop inner join")

        // Join's two branches: sorted outer + filtered inner lookup.
        XCTAssertEqual(join.children.count, 2)
        let sort = join.children[0]
        XCTAssertEqual(sort.operation, "Sort: u.`name`")
        let scan = sort.children[0]
        XCTAssertEqual(scan.operation, "Table scan on u")
        XCTAssertEqual(scan.actualRows, 25)
        XCTAssertTrue(scan.children.isEmpty)

        let filter = join.children[1]
        XCTAssertEqual(filter.operation, "Filter: (o.amount > 20.00)")
        // Fractional per-loop average rounds to nearest integer.
        XCTAssertEqual(filter.actualRows, 1)

        let indexLookup = filter.children[0]
        XCTAssertEqual(indexLookup.operation, "Index lookup on o using idx_user (user_id=u.id)",
                       "inline conditions stay part of the operation text")
        XCTAssertEqual(indexLookup.actualRows, 2)
        XCTAssertNotNil(indexLookup.actualTimeMilliseconds)
    }

    func testNeverExecutedBranchLeavesActualsNil() throws {
        let plan = try ExplainParser.parse(Self.neverExecutedFixture)
        XCTAssertEqual(plan.actualRows, 0)

        let sort = plan.children[0]
        XCTAssertTrue(sort.operation.contains("limit input to 10 row(s) per chunk"))

        // Walk down to the join's second branch (the killed-off lookup).
        let stream = sort.children[0]
        let join = stream.children[0]
        let lookup = join.children[1]
        XCTAssertEqual(lookup.operation, "Single-row index lookup on u using PRIMARY (id=o.user_id)")
        XCTAssertNil(lookup.actualRows, "(never executed) must leave actualRows nil")
        XCTAssertNil(lookup.actualTimeMilliseconds)
        XCTAssertNotNil(lookup.detail, "cost annotation still present")
    }

    func testPlainTreeWithoutActualsLeavesOptionalsNil() throws {
        let plan = try ExplainParser.parse(Self.plainTreeFixture)
        XCTAssertEqual(plan.operation, "Filter: (b3_probe_users.`name` = 'u3')")
        XCTAssertEqual(plan.detail, "cost=2.75 rows=2.5")
        XCTAssertNil(plan.actualRows)
        XCTAssertNil(plan.actualTimeMilliseconds)

        XCTAssertEqual(plan.children.count, 1)
        XCTAssertEqual(plan.children[0].operation, "Table scan on b3_probe_users")
        XCTAssertEqual(plan.children[0].detail, "cost=2.75 rows=25")
        XCTAssertNil(plan.children[0].actualRows)
    }

    func testRootWithoutCostGroupStillParses() throws {
        let fixture = """
        -> Rows fetched before execution  (cost=0..0 rows=1) (actual time=125e-6..125e-6 rows=1 loops=1)
        """
        let plan = try ExplainParser.parse(fixture)
        XCTAssertEqual(plan.operation, "Rows fetched before execution")
        XCTAssertEqual(plan.actualRows, 1)
        XCTAssertEqual(plan.actualTimeMilliseconds!, 125e-6, accuracy: 1e-15,
                       "scientific notation times must parse")
    }

    func testEmptyOutputThrows() {
        XCTAssertThrowsError(try ExplainParser.parse(""))
        XCTAssertThrowsError(try ExplainParser.parse("\n   \n"))
    }
}

// MARK: - MutationExecutor placeholder counting (Batch 3 Task D)

/// MySQL-dialect `?` scanning — strings, identifiers, and comments must hide
/// their placeholders; live SQL text must count them.
final class PlaceholderCountUnitTests: XCTestCase {
    func testCountsPlainPlaceholders() {
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "UPDATE t SET a = ? WHERE b = ? AND c = ?"), 3)
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "DELETE FROM t WHERE id = ?"), 1)
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "INSERT INTO t VALUES (?, ?, ?)"), 3)
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "UPDATE t SET a = 1"), 0)
    }

    func testIgnoresPlaceholdersInsideStringLiterals() {
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: #"UPDATE t SET a = 'x ? y' WHERE b = ?"#),
            1
        )
        // Doubled quote inside the literal must not terminate it early.
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: "SELECT * FROM t WHERE note = 'it''s ? here' AND id = ?"),
            1
        )
    }

    func testBackslashEscapedQuoteKeepsPlaceholderInsideString() {
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: #"UPDATE t SET a = 'don\'t?' WHERE b = ?"#),
            1
        )
        // Backslash at end of string escapes the closing quote…
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: #"SELECT 'ends with \' ?"#),
            0,
            "the ? sits inside an unterminated literal"
        )
    }

    func testIgnoresPlaceholdersInsideDoubleQuotedLiterals() {
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: #"UPDATE t SET a = "x ? y" WHERE b = ?"#),
            1
        )
    }

    func testIgnoresPlaceholdersInsideBacktickIdentifiers() {
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: "UPDATE `weird ? name` SET a = ? WHERE id = ?"),
            2
        )
        // Doubled backtick inside identifier stays inside.
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "SELECT `a``b ? c` FROM t"), 0)
    }

    func testIgnoresPlaceholdersInLineComments() {
        // "--" comment (requires trailing whitespace per MySQL).
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: "-- filter rows ?\nWHERE id = ?"),
            1
        )
        // "#" comment.
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: "# filter rows ?\nWHERE id = ?"),
            1
        )
    }

    func testDoubleDashWithoutWhitespaceIsNotAComment() {
        // MySQL lexes a--? as subtraction of negation, so the ? is live SQL.
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "SELECT a--b ? FROM t"), 1)
        // But "-- " with a space IS a comment.
        XCTAssertEqual(MutationExecutor.placeholderCount(in: "SELECT a -- ?\nFROM t WHERE x = ?"), 1)
    }

    func testIgnoresPlaceholdersInsideBlockCommentsWithoutNesting() {
        // MySQL block comments do NOT nest: first */ closes.
        XCTAssertEqual(
            MutationExecutor.placeholderCount(in: "/* outer ? */ SELECT ? /* trailing ? */"),
            1
        )
    }
}
