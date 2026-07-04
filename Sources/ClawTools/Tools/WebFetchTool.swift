import ClawCore
import Foundation

/// GET-only public-web fetch (§7.2). Redirects are followed MANUALLY (the injected client never
/// auto-follows): per hop the host is resolved and every address asserted public, so a redirect
/// into a private range is refused regardless of where the chain started. Resolve-then-connect
/// TOCTOU (DNS rebinding) is the documented v1 residual (§20 item 3).
public struct WebFetchTool: Tool {
  static let contentTypeAllowlistPrefixes = ["text/"]
  static let contentTypeAllowlistExact = [
    "application/json", "application/xml", "application/xhtml+xml",
  ]

  private let http: any HTTPExecuting
  private let resolver: any AddressResolving
  private let redactor: SecretRedactor
  private let maxBodyBytes: Int
  private let maxHops: Int
  private let outputCapGraphemes: Int

  public init(
    http: any HTTPExecuting,
    resolver: any AddressResolving,
    redactor: SecretRedactor,
    maxBodyBytes: Int = 2 * 1024 * 1024,
    maxHops: Int = 5,
    outputCapGraphemes: Int = ToolOutputCap.maxGraphemes
  ) {
    self.http = http
    self.resolver = resolver
    self.redactor = redactor
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
      ])
    )
  }

  public var timeout: Duration { .seconds(30) }

  public func execute(arguments: JSONValue) async -> ToolPayload {
    guard let rawURL = arguments.objectValue?["url"]?.stringValue, rawURL.isEmpty == false else {
      return errorPayload("web_fetch needs a non-empty \"url\" argument.")
    }

    var currentURL: String
    switch CanonicalURL.canonicalize(rawURL) {
    case .success(let canonical):
      currentURL = canonical
    case .failure(let policyError):
      return errorPayload(Self.describe(policyError))
    }

    let deadline = ContinuousClock.now + timeout
    var hopsRemaining = maxHops

    while true {
      guard let host = URLComponents(string: currentURL)?.host else {
        return errorPayload("Could not parse the host of \(currentURL).")
      }

      let addresses: [ResolvedAddress]
      do {
        addresses = try await resolver.resolve(host: host)
      } catch {
        return errorPayload("Could not resolve \(host).")
      }

      guard addresses.isEmpty == false,
        addresses.allSatisfy({ address in SSRFGuard.isPublic(address) })
      else {
        return ToolPayload(
          content: "Refused: \(host) resolves to a private or reserved address.",
          status: .blockedSSRF,
          ingestedUntrusted: false
        )
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
        guard hopsRemaining > 0 else {
          return errorPayload("Too many redirects (more than \(maxHops)).")
        }
        hopsRemaining -= 1

        guard let location = result.getHeader(for: "Location") else {
          return errorPayload("Redirect (HTTP \(result.statusCode)) without a Location header.")
        }
        let nextRaw = Self.resolveLocation(location, against: currentURL)
        switch CanonicalURL.canonicalize(nextRaw) {
        case .success(let canonical):
          currentURL = canonical
          continue
        case .failure(let policyError):
          return errorPayload("Redirect target refused: \(Self.describe(policyError))")
        }
      }

      guard (200..<300).contains(result.statusCode) else {
        return errorPayload("The server answered HTTP \(result.statusCode).")
      }

      return successPayload(result)
    }
  }

  // MARK: - Load-bearing

  private func successPayload(_ result: HTTPResult) -> ToolPayload {
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
    let redacted = redactor.redact(extracted)  // rev.1 L5 — same pass as file_read

    return ToolPayload(
      content: ToolOutputCap.cap(redacted, maxGraphemes: outputCapGraphemes),
      status: .ok,
      ingestedUntrusted: true
    )
  }

  /// Relative `Location` values resolve against the current hop URL.
  private static func resolveLocation(_ location: String, against current: String) -> String {
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

  private static func describe(_ policyError: CanonicalURLError) -> String {
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

  private func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }
}
