import ClawCore
import Foundation
import Testing

@testable import ClawTools

/// Scripted HTTP: URL → result (or error). Records requested URLs so tests can assert what was
/// (and was NOT) dispatched.
actor ScriptedHTTP: HTTPExecuting {
  private let responses: [String: HTTPResult]
  private(set) var requestedURLs: [String] = []

  init(responses: [String: HTTPResult]) {
    self.responses = responses
  }

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    struct PostUnsupported: Error {}
    throw PostUnsupported()
  }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    requestedURLs.append(url)
    guard let scripted = responses[url] else {
      struct Unscripted: Error { let url: String }
      throw Unscripted(url: url)
    }
    return scripted
  }
}

/// Scripted DNS: host → addresses.
struct ScriptedResolver: AddressResolving {
  let table: [String: [ResolvedAddress]]

  func resolve(host: String) async throws -> [ResolvedAddress] {
    if let literal = ResolvedAddress.parse(host) {
      return [literal]
    }
    guard let addresses = table[host] else {
      throw AddressResolutionError.unresolvable(host: host)
    }
    return addresses
  }
}

@Suite struct WebFetchToolTests {
  private let publicAddress: ResolvedAddress
  private let privateAddress: ResolvedAddress

  init() throws {
    publicAddress = try #require(ResolvedAddress.parse("93.184.216.34"))
    privateAddress = try #require(ResolvedAddress.parse("10.0.0.5"))
  }

  private func htmlResult(_ body: String, status: Int = 200) -> HTTPResult {
    HTTPResult(
      statusCode: status,
      headers: ["Content-Type": "text/html; charset=utf-8"],
      body: Data(body.utf8)
    )
  }

  private func makeTool(http: ScriptedHTTP, resolver: ScriptedResolver) -> WebFetchTool {
    WebFetchTool(
      http: http,
      resolver: resolver,
      redactor: SecretRedactor(secretValues: ["tok-secret-1"])
    )
  }

  private func fetch(_ tool: WebFetchTool, url: String) async -> ToolPayload {
    await tool.execute(arguments: .object(["url": .string(url)]))
  }

  @Test func fetchesExtractsAndRedactsHTML() async throws {
    // given
    let http = ScriptedHTTP(responses: [
      "https://example.com/a": htmlResult(
        "<html><body><p>Hello tok-secret-1 world</p></body></html>"
      )
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["example.com": [publicAddress]])
    )

    // when
    let payload = await fetch(tool, url: "https://Example.com/a")

    // then — canonicalized before dispatch; HTML stripped; secret redacted (rev.1 L5)
    #expect(payload.status == .ok)
    #expect(payload.content.contains("Hello [REDACTED:secret-value] world"))
    #expect(payload.ingestedUntrusted)
    #expect(await http.requestedURLs == ["https://example.com/a"])
  }

  @Test func privateResolutionIsBlockedBeforeAnyRequest() async throws {
    // given — a public-looking host resolving to RFC-1918 (SC3 clause 5)
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["internal.example": [privateAddress]])
    )

    // when
    let payload = await fetch(tool, url: "https://internal.example/")

    // then — blocked, and the stub saw NOTHING
    #expect(payload.status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func mixedResolutionIsBlocked() async throws {
    // given — EVERY returned address must be public (§7.2)
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["dual.example": [publicAddress, privateAddress]])
    )

    // when / then
    #expect((await fetch(tool, url: "https://dual.example/")).status == .blockedSSRF)
  }

  @Test func emptyResolutionIsBlockedBeforeAnyRequest() async throws {
    // given — a resolver that returns ZERO addresses must NOT vacuously pass the SSRF check
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(http: http, resolver: ScriptedResolver(table: ["empty.example": []]))

    // when
    let payload = await fetch(tool, url: "https://empty.example/")

    // then — refused as SSRF, and the stub saw NOTHING
    #expect(payload.status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func redirectIntoPrivateRangeIsBlockedMidChain() async throws {
    // given — public host 301s to a private-resolving host (the blocklist re-runs per hop)
    let http = ScriptedHTTP(responses: [
      "https://example.com/start": HTTPResult(
        statusCode: 301,
        headers: ["Location": "https://internal.example/steal"],
        body: Data()
      )
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: [
        "example.com": [publicAddress],
        "internal.example": [privateAddress],
      ])
    )

    // when
    let payload = await fetch(tool, url: "https://example.com/start")

    // then — hop 1 requested, hop 2 refused before any request
    #expect(payload.status == .blockedSSRF)
    #expect(await http.requestedURLs == ["https://example.com/start"])
  }

  @Test func followsAtMostFiveHops() async throws {
    // given — an endless redirect chain
    var responses: [String: HTTPResult] = [:]
    for hop in 0...6 {
      responses["https://example.com/hop\(hop)"] = HTTPResult(
        statusCode: 302,
        headers: ["Location": "https://example.com/hop\(hop + 1)"],
        body: Data()
      )
    }
    let http = ScriptedHTTP(responses: responses)
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["example.com": [publicAddress]])
    )

    // when
    let payload = await fetch(tool, url: "https://example.com/hop0")

    // then — 5 hops max (the start + 5 redirect follows = 6 requests), then a plain error
    #expect(payload.status == .error)
    #expect(await http.requestedURLs.count == 6)
  }

  @Test func refusesDisallowedContentType() async throws {
    // given
    let http = ScriptedHTTP(responses: [
      "https://example.com/blob": HTTPResult(
        statusCode: 200,
        headers: ["Content-Type": "application/octet-stream"],
        body: Data([0x00, 0x01])
      )
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["example.com": [publicAddress]])
    )

    // when / then
    #expect((await fetch(tool, url: "https://example.com/blob")).status == .error)
  }

  @Test func allowsJSONAndSuffixTypes() async throws {
    // given
    let http = ScriptedHTTP(responses: [
      "https://example.com/api": HTTPResult(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"ok":true}"#.utf8)
      ),
      "https://example.com/feed": HTTPResult(
        statusCode: 200,
        headers: ["Content-Type": "application/atom+xml"],
        body: Data("<feed><title>News</title></feed>".utf8)
      ),
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["example.com": [publicAddress]])
    )

    // when / then
    #expect((await fetch(tool, url: "https://example.com/api")).status == .ok)
    #expect((await fetch(tool, url: "https://example.com/feed")).status == .ok)
  }

  @Test func urlPolicyRefusalsAreErrorsNotSSRF() async throws {
    // given
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(http: http, resolver: ScriptedResolver(table: [:]))

    // when / then — scheme/port/userinfo/IDN refusals come from CanonicalURL, pre-dispatch
    #expect((await fetch(tool, url: "ftp://example.com/")).status == .error)
    #expect((await fetch(tool, url: "https://user:pw@example.com/")).status == .error)
    #expect((await fetch(tool, url: "https://example.com:8443/")).status == .error)
    #expect((await fetch(tool, url: "https://exämple.com/")).status == .error)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func nonSuccessStatusIsAnError() async throws {
    // given
    let http = ScriptedHTTP(responses: [
      "https://example.com/gone": htmlResult("<html>gone</html>", status: 404)
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["example.com": [publicAddress]])
    )

    // when
    let payload = await fetch(tool, url: "https://example.com/gone")

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("404"))
  }
}
