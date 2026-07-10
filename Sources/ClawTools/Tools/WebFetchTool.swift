import ClawCore
import Foundation

/// GET-only public-web fetch. Redirects are followed MANUALLY (the injected client never
/// auto-follows): per hop the host is resolved and every address asserted public, so a redirect
/// into a private range is refused regardless of where the chain started. Resolve-then-connect
/// TOCTOU (DNS rebinding) is the documented v1 residual.
public struct WebFetchTool: Tool {
  static let contentTypeAllowlistPrefixes = ["text/"]
  static let contentTypeAllowlistExact = [
    "application/json", "application/xml", "application/xhtml+xml",
  ]

  private let http: any HTTPExecuting
  private let resolver: any AddressResolving
  private let redactor: SecretRedactor
  private let exemptCIDRs: [CIDR]
  private let fakeIPDetector: any FakeIPDetecting
  private let maxBodyBytes: Int
  private let maxHops: Int
  private let outputCapGraphemes: Int

  public init(
    http: any HTTPExecuting,
    resolver: any AddressResolving,
    redactor: SecretRedactor,
    exemptCIDRs: [CIDR] = [],
    fakeIPDetector: (any FakeIPDetecting)? = nil,
    maxBodyBytes: Int = 2 * 1024 * 1024,
    maxHops: Int = 5,
    outputCapGraphemes: Int = ToolOutputCap.maxGraphemes
  ) {
    self.http = http
    self.resolver = resolver
    self.redactor = redactor
    self.exemptCIDRs = exemptCIDRs
    self.fakeIPDetector = fakeIPDetector ?? FakeIPDetector(resolver: resolver)
    self.maxBodyBytes = maxBodyBytes
    self.maxHops = maxHops
    self.outputCapGraphemes = outputCapGraphemes
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "web_fetch",
      description: "Fetch a public http(s) URL and return its readable text.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "url": .object([
            "type": .string("string"),
            "description": .string("The absolute http(s) URL to fetch."),
          ])
        ]),
        "required": .array([.string("url")]),
      ]),
      egressClass: .arbitraryDestination,
      riskLevel: .safe
    )
  }

  public var timeout: Duration { .seconds(30) }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    guard let rawURL = arguments.objectValue?["url"]?.stringValue, rawURL.isEmpty == false else {
      return .refused(reason: "web_fetch needs a non-empty \"url\" argument.")
    }
    switch CanonicalURL.canonicalize(rawURL) {
    case .success(let canonical):
      return .resolved(canonical)
    case .failure(let policyError):
      return .refused(reason: Self.describe(policyError))
    }
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    // The gate resolved and authorized exactly this canonical URL; re-deriving it here
    // could drift byte-for-byte from what the owner approved.
    guard let canonicalTarget else {
      return errorPayload("web_fetch was dispatched without a gate-resolved URL.")
    }
    var currentURL = canonicalTarget

    let deadline = ContinuousClock.now + timeout
    var hopsRemaining = maxHops

    while true {
      guard let host = URLComponents(string: currentURL)?.host else {
        return errorPayload("Could not parse the host of \(currentURL).")
      }

      if let refusal = await refusalForNonPublicHost(host) {
        return refusal
      }

      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else {
        return errorPayload("The fetch timed out.")
      }
      let remainingSeconds = max(1, Int(remaining.components.seconds))

      let result: HTTPResult
      do {
        result = try await http.get(
          url: currentURL,
          headers: [:],
          timeoutSeconds: remainingSeconds,
          maxBodyBytes: maxBodyBytes
        )
      } catch {
        return errorPayload(
          "The fetch failed: the site did not respond or the body exceeded 2 MiB."
        )
      }

      if (300..<400).contains(result.statusCode) {
        switch redirectStep(after: result, current: currentURL, hopsRemaining: &hopsRemaining) {
        case .follow(let nextURL):
          currentURL = nextURL
          continue
        case .refused(let payload):
          return payload
        }
      }

      guard (200..<300).contains(result.statusCode) else {
        return errorPayload("The server answered HTTP \(result.statusCode).")
      }

      return successPayload(result)
    }
  }
}

// MARK: - Fetch Loop Steps

private extension WebFetchTool {
  enum RedirectStep {
    case follow(String)
    case refused(ToolPayload)
  }

  /// Per-hop SSRF assertion: resolves the host and returns the refusal/error payload unless every
  /// resolved address is public; nil means the hop may proceed. Two scoped widenings, both
  /// owner-trusted egress (a fake-IP proxy tunnels the connection and re-resolves the real name
  /// at its edge): an address inside an owner-configured exempt CIDR passes, and an address
  /// inside the benchmarking range passes when a fresh canary probe confirms fake-IP DNS
  /// interception. Every other blocklist row — loopback, RFC-1918, link-local/metadata — is
  /// refused unconditionally.
  func refusalForNonPublicHost(_ host: String) async -> ToolPayload? {
    let addresses: [ResolvedAddress]
    do {
      addresses = try await resolver.resolve(host: host)
    } catch {
      return errorPayload("Could not resolve \(host).")
    }

    guard addresses.isEmpty == false else {
      return refusalPayload("Refused: \(host) resolves to a private or reserved address.")
    }

    // The widenings below apply to resolved hostnames only: a fake-IP resolver never rewrites
    // a literal, and pool addresses recycle, so a literal target inside the pool is meaningless.
    // Literals stay on the pure blocklist — including the legacy numeric spellings getaddrinfo
    // resolves without DNS (http://3323068500/), which strict IP-literal parsing would miss.
    if ResolvedAddress.denotesIPLiteral(host: host) {
      guard addresses.allSatisfy({ address in SSRFGuard.isPublic(address) }) else {
        return refusalPayload("Refused: \(host) is a private or reserved address.")
      }
      return nil
    }

    let refusable = addresses.filter { address in
      SSRFGuard.isPublic(address) == false
        && exemptCIDRs.contains { cidr in cidr.contains(address) } == false
    }
    guard let firstRefusable = refusable.first else {
      return nil
    }

    let allInBenchmarkRange = refusable.allSatisfy { address in
      SSRFGuard.benchmarkRange.contains(address)
    }
    if allInBenchmarkRange {
      if case .active = await fakeIPDetector.detect() {
        return nil
      }
      return refusalPayload(
        """
        Refused: \(host) resolves to \(firstRefusable) inside \(SSRFGuard.benchmarkRange) — \
        the reserved range fake-IP VPN/proxies use as their pool, but a fresh DNS probe did not \
        confirm fake-IP mode. If you run such a proxy, set \
        \(AppConfig.EnvKey.webFetchExemptCIDRs)=\(SSRFGuard.benchmarkRange) to exempt the pool.
        """
      )
    }

    return refusalPayload(
      "Refused: \(host) resolves to \(firstRefusable), a private or reserved address."
    )
  }

  func refusalPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .blockedSSRF, ingestedUntrusted: false)
  }

  /// One 3xx hop: consumes a hop from the budget and re-canonicalizes the Location target so the
  /// next iteration re-runs the full per-hop policy on it.
  func redirectStep(
    after result: HTTPResult,
    current: String,
    hopsRemaining: inout Int
  ) -> RedirectStep {
    guard hopsRemaining > 0 else {
      return .refused(errorPayload("Too many redirects (more than \(maxHops))."))
    }
    hopsRemaining -= 1

    guard let location = result.getHeader(for: "Location") else {
      return .refused(
        errorPayload("Redirect (HTTP \(result.statusCode)) without a Location header.")
      )
    }
    let nextRaw = Self.resolveLocation(location, against: current)
    switch CanonicalURL.canonicalize(nextRaw) {
    case .success(let canonical):
      return .follow(canonical)
    case .failure(let policyError):
      return .refused(errorPayload("Redirect target refused: \(Self.describe(policyError))"))
    }
  }
}

// MARK: - Load-bearing

private extension WebFetchTool {
  func successPayload(_ result: HTTPResult) -> ToolPayload {
    let contentType = (result.getHeader(for: "Content-Type") ?? "").lowercased()
    let mediaType = contentType.split(separator: ";").first.map(String.init) ?? ""

    let allowed =
      Self.contentTypeAllowlistPrefixes.contains { prefix in mediaType.hasPrefix(prefix) }
      || Self.contentTypeAllowlistExact.contains(mediaType)
      || mediaType.hasSuffix("+xml") || mediaType.hasSuffix("+json")

    guard allowed else {
      return errorPayload("Refused content type \(mediaType.isEmpty ? "unknown" : mediaType).")
    }

    guard let bodyText = String(data: result.body, encoding: .utf8) else {
      return errorPayload("The response body is not UTF-8 text.")
    }

    let extracted =
      mediaType.contains("html") ? HTMLTextExtractor.extractText(fromHTML: bodyText) : bodyText
    let redacted = redactor.redact(extracted)  // same pass as file_read

    return ToolPayload(
      content: ToolOutputCap.cap(redacted, maxGraphemes: outputCapGraphemes),
      status: .ok,
      ingestedUntrusted: true
    )
  }

  /// Relative `Location` values resolve against the current hop URL.
  static func resolveLocation(_ location: String, against current: String) -> String {
    if location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://") {
      return location
    }

    guard
      let base = URL(string: current),
      let resolved = URL(string: location, relativeTo: base)
    else {
      return location
    }

    return resolved.absoluteString
  }

  static func describe(_ policyError: CanonicalURLError) -> String {
    switch policyError {
    case .unparseable:
      return "That is not a valid URL."
    case .unsupportedScheme(let scheme):
      return "Only http and https URLs are supported (got \(scheme))."
    case .nonASCIIHost:
      return "Internationalized (non-ASCII/punycode) hosts are not supported in v1."
    case .userinfoPresent:
      return "URLs with embedded credentials are not allowed."
    case .unsupportedPort(let port):
      return "Only ports 80 and 443 are allowed (got \(port))."
    }
  }

  func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }
}
