/// Backtick-quoted MySQL identifier rendering for the few places where a name
/// must appear inside SQL text (`SHOW CREATE TABLE`, admin DDL, browse
/// queries).
///
/// Embedded backticks are doubled per MySQL's own escaping rule, so
/// `quote("we`ird")` → `` `we``ird` ``. Everything else — case, spaces,
/// dollars, dots — is preserved verbatim between the quotes.
enum IdentifierQuoting {
    /// Renders `identifier` as a quoted SQL identifier: `` `ident` ``.
    static func quote(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }
}
