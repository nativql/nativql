import NativQLKit
import NIOSSL

extension TLSConfiguration {
    /// Builds the NIOSSL client configuration handed to MySQLNIO's
    /// `MySQLConnection.connect(tlsConfiguration:)` parameter.
    ///
    /// Deviation from the PostgresNIO mapping, pinned against MySQLNIO 1.9.1:
    /// the library has **no** TLS policy enum (`Configuration.TLS` does not
    /// exist). Its handshake handler treats `tlsConfiguration == nil` as
    /// plaintext-only (no `SSLRequest` is sent), and a non-nil value as
    /// "attempt the TLS upgrade". Consequently:
    ///
    /// - `.disable` → `nil`.
    /// - `.prefer` and `.require` both return a non-validating client config;
    ///   they are indistinguishable on the wire because MySQLNIO 1.x silently
    ///   downgrades to plaintext if the server does not advertise
    ///   `CLIENT_SSL`. There is no API to enforce "encryption or fail".
    ///   Practical exposure is nil for MySQL ≥ 5.7, which always advertises
    ///   `CLIENT_SSL`; a genuine TLS failure mid-handshake (bad context,
    ///   rejected certificate) still surfaces as an error.
    /// - `.verifyCA` verifies the certificate chain but not the hostname via
    ///   NIOSSL's `noHostnameVerification` (present in the pinned NIOSSL).
    /// - `.verifyFull` additionally checks the hostname against the host the
    ///   driver passes as `serverHostname` at connect time.
    ///
    /// - Parameters:
    ///   - mode: The SSL mode selected in the connection form.
    ///
    /// Non-throwing by design: assembling the configuration struct cannot
    /// fail. (PostgresNIO's mapping throws because it builds an
    /// `NIOSSLContext` eagerly; MySQLNIO constructs its own context during the
    /// handshake instead.) Client-certificate support, if added later, would
    /// reintroduce fallibility.
    static func makeMySQLClient(for mode: SSLMode) -> Self? {
        switch mode {
        case .disable:
            // Plaintext only: MySQLNIO skips the SSLRequest entirely.
            return nil

        case .prefer:
            // Opportunistic TLS: encrypt if the server supports it, with no
            // certificate validation (libpq "prefer" semantics).
            return makeClient(verification: .none)

        case .require:
            // Encryption intended; certificates NOT validated (libpq "require"
            // semantics). See deviation note above re: silent downgrade.
            return makeClient(verification: .none)

        case .verifyCA:
            // Chain verification WITHOUT hostname check — true verify-ca
            // semantics, available in the pinned NIOSSL 2.37.2.
            return makeClient(verification: .noHostnameVerification)

        case .verifyFull:
            // Chain AND hostname verification.
            return makeClient(verification: .fullVerification)
        }
    }

    private static func makeClient(verification: CertificateVerification) -> Self {
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = verification
        return tlsConfiguration
    }
}
