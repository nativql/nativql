import NativQLKit
import NIOSSL
import PostgresNIO

extension PostgresConnection.Configuration.TLS {
    /// Maps the app-level `SSLMode` onto a PostgresNIO TLS policy.
    ///
    /// - Parameters:
    ///   - mode: The SSL mode selected in the connection form.
    ///   - serverName: Optional SNI / certificate-validation name override.
    /// - Throws: `DriverError.tlsFailed` when the NIOSSL context cannot be built
    ///   (e.g. malformed client-certificate configuration in future revisions).
    static func makeTLS(for mode: SSLMode, serverName: String? = nil) throws -> Self {
        switch mode {
        case .disable:
            return .disable

        case .prefer:
            // Opportunistic TLS: encrypt if the server supports it. libpq's
            // "prefer" performs no certificate validation, so neither do we.
            return .prefer(try makeContext(verification: .none))

        case .require:
            // Encryption mandatory; certificate NOT validated (libpq semantics).
            return .require(try makeContext(verification: .none))

        case .verifyCA:
            // Verify the certificate chain against the trust store but do NOT
            // check the hostname. The plan anticipated NIOSSL lacking a
            // no-hostname option and suggested degrading to fullVerification;
            // the pinned NIOSSL (2.37.2) exposes
            // `CertificateVerification.noHostnameVerification`, so true
            // verify-ca semantics are implemented here.
            return .require(try makeContext(verification: .noHostnameVerification))

        case .verifyFull:
            // Chain AND hostname verification.
            return .require(try makeContext(verification: .fullVerification))
        }
    }

    private static func makeContext(
        verification: CertificateVerification
    ) throws -> NIOSSLContext {
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = verification
        do {
            return try NIOSSLContext(configuration: tlsConfiguration)
        } catch {
            throw DriverError.tlsFailed("failed to build TLS context: \(error)")
        }
    }
}
