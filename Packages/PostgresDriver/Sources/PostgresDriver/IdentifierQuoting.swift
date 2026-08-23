/// Double-quoted PostgreSQL identifier rendering for the few places where a
/// name must appear inside SQL text (DDL reconstruction, browse queries).
///
/// Embedded double quotes are doubled per SQL standard, so
/// `quote("we\"ird")` → `"we""ird"`. Everything else — case, spaces, `$`,
/// dots — is preserved verbatim between the quotes.
enum IdentifierQuoting {
    /// Renders `identifier` as a quoted SQL identifier: `"ident"`.
    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
