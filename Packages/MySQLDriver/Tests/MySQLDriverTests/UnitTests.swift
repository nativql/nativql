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
