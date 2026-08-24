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
