import ClawCore

// MARK: - Credential header merge

/// Folds a credential source's header contribution into an adapter's own wire headers under an
/// allowlist, the one way both wire adapters do it.
///
/// The seam between an adapter and its credential source is a plain dictionary, so without an
/// allowlist any source could rewrite `Host`, content negotiation, client identity, or session
/// routing on the way to the wire. A name outside the allowlist, one the adapter already owns, or a
/// second casing of a name already merged is refused rather than seated — and every refusal quotes
/// only the offending name, never the value it arrived with.
enum CredentialHeaderMerge {
  /// Adds allowed credential headers without replacing adapter-owned headers.
  ///
  /// - Parameters:
  ///   - adapterHeaders: The headers owned by the adapter's request framing.
  ///   - allowlist: Lowercase credential-header names mapped to their canonical wire spelling.
  ///   - authorization: Credential headers and exact values that must be redacted.
  /// - Returns: The adapter headers combined with the accepted credential headers.
  /// - Throws: A terminal `ProviderError` for an unapproved name, an adapter-header collision,
  ///   or duplicate names that differ only in case; the error never includes a header value.
  static func merged(
    into adapterHeaders: [String: String],
    allowing allowlist: [String: String],
    from authorization: LLMRequestAuthorization
  ) throws -> [String: String] {
    var merged = adapterHeaders
    let owned = Set(
      adapterHeaders.keys.map { name in
        name.lowercased()
      }
    )

    // Sorted so a source offering several bad headers always names the same one first.
    for name in authorization.headers.keys.sorted() {
      let normalized = name.lowercased()
      guard let canonical = allowlist[normalized] else {
        throw ProviderError.terminal(
          status: nil,
          message: "credential header \(name) is not accepted by this route"
        )
      }
      guard owned.contains(normalized) == false else {
        throw ProviderError.terminal(
          status: nil,
          message: "credential header \(name) would replace a wire header"
        )
      }
      // Two spellings of the same allowlisted name (e.g. `Authorization` and `authorization`)
      // collapse to one canonical key, so a silent overwrite would let sort order decide which
      // bearer reaches the wire. Reject the collision rather than merge it.
      guard merged[canonical] == nil else {
        throw ProviderError.terminal(
          status: nil,
          message: "credential header \(name) was supplied more than once"
        )
      }
      merged[canonical] = authorization.headers[name]
    }
    return merged
  }
}
