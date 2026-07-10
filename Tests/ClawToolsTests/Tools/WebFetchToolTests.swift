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

/// Scripted probe: always answers with the canned detection.
struct ScriptedFakeIPDetector: FakeIPDetecting {
  let detection: FakeIPDetection

  func detect() async -> FakeIPDetection {
    detection
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

  private func makeTool(
    http: ScriptedHTTP,
    resolver: ScriptedResolver,
    exemptCIDRs: [CIDR] = [],
    fakeIPDetector: (any FakeIPDetecting)? = nil
  ) -> WebFetchTool {
    WebFetchTool(
      http: http,
      resolver: resolver,
      redactor: SecretRedactor(secretValues: ["tok-secret-1"]),
      exemptCIDRs: exemptCIDRs,
      fakeIPDetector: fakeIPDetector
    )
  }

  /// The gate resolves the canonical URL and hands it to `execute`; these tests stand in for the
  /// gate by canonicalizing the raw URL the same way before dispatch.
  private func fetch(_ tool: WebFetchTool, url: String) async -> ToolPayload {
    let canonicalTarget: String
    switch CanonicalURL.canonicalize(url) {
    case .success(let canonical):
      canonicalTarget = canonical
    case .failure:
      canonicalTarget = url
    }
    return await tool.execute(
      arguments: .object(["url": .string(url)]),
      canonicalTarget: canonicalTarget
    )
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

  @Test func urlPolicyRefusalsAreRefusedAtResolutionNotDispatched() async throws {
    // given — scheme/port/userinfo/IDN refusals come from CanonicalURL, at the gate's resolution
    // step (the tool no longer re-canonicalizes in execute), so they never reach dispatch
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(http: http, resolver: ScriptedResolver(table: [:]))

    // when / then — each raw URL resolves to a refusal carrying the specific policy copy
    func resolution(_ url: String) -> CanonicalTargetResolution? {
      tool.canonicalTarget(arguments: .object(["url": .string(url)]))
    }
    #expect(
      resolution("ftp://example.com/")
        == .refused(reason: "Only http and https URLs are supported (got ftp).")
    )
    #expect(
      resolution("https://user:pw@example.com/")
        == .refused(reason: "URLs with embedded credentials are not allowed.")
    )
    #expect(
      resolution("https://example.com:8443/")
        == .refused(reason: "Only ports 80 and 443 are allowed (got 8443).")
    )
    #expect(
      resolution("https://exämple.com/")
        == .refused(reason: "Internationalized (non-ASCII/punycode) hosts are not supported in v1.")
    )
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func missingUrlIsRefusedAtResolution() async throws {
    // given — the gate's resolution step rejects a missing/empty url with the unified copy
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(http: http, resolver: ScriptedResolver(table: [:]))

    // when / then
    #expect(
      tool.canonicalTarget(arguments: .object([:]))
        == .refused(reason: #"web_fetch needs a non-empty "url" argument."#)
    )
    #expect(
      tool.canonicalTarget(arguments: .object(["url": .string("")]))
        == .refused(reason: #"web_fetch needs a non-empty "url" argument."#)
    )
  }

  @Test func benchmarkResolutionProceedsWhenFakeIPModeIsConfirmed() async throws {
    // given — DNS hijacked by a fake-IP proxy: a public host answers from 198.18.0.0/15 and a
    // fresh canary probe confirms interception (issue #26)
    let fakeIPAddress = try #require(ResolvedAddress.parse("198.18.0.84"))
    let http = ScriptedHTTP(responses: [
      "https://blog.example/post": htmlResult("<html><body><p>the article</p></body></html>")
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["blog.example": [fakeIPAddress]]),
      fakeIPDetector: ScriptedFakeIPDetector(detection: .active(sample: fakeIPAddress))
    )

    // when
    let payload = await fetch(tool, url: "https://blog.example/post")

    // then — the fetch egresses through the owner's tunnel instead of being refused
    #expect(payload.status == .ok)
    #expect(payload.content.contains("the article"))
  }

  @Test func benchmarkResolutionIsRefusedWhenProbeDoesNotConfirm() async throws {
    // given — a benchmark-range answer WITHOUT confirmed fake-IP interception
    let fakeIPAddress = try #require(ResolvedAddress.parse("198.18.0.84"))
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["blog.example": [fakeIPAddress]]),
      fakeIPDetector: ScriptedFakeIPDetector(detection: .inactive)
    )

    // when
    let payload = await fetch(tool, url: "https://blog.example/post")

    // then — refused before any request, and the copy names the address, the range, and the
    // opt-in env key so the failure is diagnosable instead of silent
    #expect(payload.status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
    #expect(payload.content.contains("\(fakeIPAddress)"))
    #expect(payload.content.contains("\(SSRFGuard.benchmarkRange)"))
    #expect(payload.content.contains(AppConfig.EnvKey.webFetchExemptCIDRs))
  }

  @Test func privateResolutionStaysBlockedEvenWithFakeIPConfirmed() async throws {
    // given — the relaxation is scoped to the benchmarking row: RFC-1918 (and loopback/metadata)
    // must stay refused no matter what the probe says
    let fakeIPSample = try #require(ResolvedAddress.parse("198.18.0.84"))
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["internal.example": [privateAddress]]),
      fakeIPDetector: ScriptedFakeIPDetector(detection: .active(sample: fakeIPSample))
    )

    // when / then
    #expect((await fetch(tool, url: "https://internal.example/")).status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func mixedBenchmarkAndPrivateResolutionIsRefused() async throws {
    // given — one pool address plus one RFC-1918 address: the private one decides
    let fakeIPAddress = try #require(ResolvedAddress.parse("198.18.0.84"))
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["dual.example": [fakeIPAddress, privateAddress]]),
      fakeIPDetector: ScriptedFakeIPDetector(detection: .active(sample: fakeIPAddress))
    )

    // when / then
    #expect((await fetch(tool, url: "https://dual.example/")).status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func exemptCIDRAllowsMatchingResolutionWithoutProbeConfirmation() async throws {
    // given — the owner exempted a fake IPv6 pool; the probe confirms nothing
    let fakeV6Address = try #require(ResolvedAddress.parse("fc00::1234"))
    let exemptBlock = try #require(CIDR.parse("fc00::/18"))
    let http = ScriptedHTTP(responses: [
      "https://blog.example/post": htmlResult("<html><body><p>via the tunnel</p></body></html>")
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["blog.example": [fakeV6Address]]),
      exemptCIDRs: [exemptBlock],
      fakeIPDetector: ScriptedFakeIPDetector(detection: .inactive)
    )

    // when
    let payload = await fetch(tool, url: "https://blog.example/post")

    // then — the manual override alone opts the block in
    #expect(payload.status == .ok)
    #expect(payload.content.contains("via the tunnel"))
  }

  @Test func exemptCIDRDoesNotCoverOtherBlockedRanges() async throws {
    // given — an exemption for the v6 pool must not leak onto RFC-1918
    let exemptBlock = try #require(CIDR.parse("fc00::/18"))
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["internal.example": [privateAddress]]),
      exemptCIDRs: [exemptBlock],
      fakeIPDetector: ScriptedFakeIPDetector(detection: .inactive)
    )

    // when / then
    #expect((await fetch(tool, url: "https://internal.example/")).status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func literalBenchmarkAddressStaysRefusedEvenWithBothWideningsAvailable() async throws {
    // given — a literal-IP URL inside the pool, with the probe confirming fake-IP mode AND an
    // exempt CIDR covering the block: the widenings apply to resolved hostnames only (a fake-IP
    // resolver never rewrites a literal, and pool addresses recycle, so a literal target is
    // meaningless there)
    let fakeIPAddress = try #require(ResolvedAddress.parse("198.18.0.84"))
    let poolBlock = try #require(CIDR.parse("198.18.0.0/15"))
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: [:]),
      exemptCIDRs: [poolBlock],
      fakeIPDetector: ScriptedFakeIPDetector(detection: .active(sample: fakeIPAddress))
    )

    // when
    let payload = await fetch(tool, url: "https://198.18.0.84/page")

    // then — refused although BOTH widenings would cover a hostname resolving to this address
    #expect(payload.status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func legacyNumericLiteralStaysRefusedEvenWhenFakeIPConfirmed() async throws {
    // given — the integer spelling of 198.18.0.84 (http://3323068500/); strict inet_pton rejects
    // it but getaddrinfo resolves it into the pool. It must still count as a literal (pure
    // blocklist), not ride either widening, even with the probe active AND the pool exempted
    let fakeIPAddress = try #require(ResolvedAddress.parse("198.18.0.84"))
    let poolBlock = try #require(CIDR.parse("198.18.0.0/15"))
    let http = ScriptedHTTP(responses: [:])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: ["3323068500": [fakeIPAddress]]),
      exemptCIDRs: [poolBlock],
      fakeIPDetector: ScriptedFakeIPDetector(detection: .active(sample: fakeIPAddress))
    )

    // when
    let payload = await fetch(tool, url: "http://3323068500/page")

    // then
    #expect(payload.status == .blockedSSRF)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test func literalPublicAddressURLStillFetches() async throws {
    // given — the literal carve-out must not over-block: a public literal is ordinary egress
    let http = ScriptedHTTP(responses: [
      "https://93.184.216.34/page": htmlResult("<html><body><p>by address</p></body></html>")
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: [:]),
      fakeIPDetector: ScriptedFakeIPDetector(detection: .inactive)
    )

    // when
    let payload = await fetch(tool, url: "https://93.184.216.34/page")

    // then
    #expect(payload.status == .ok)
    #expect(payload.content.contains("by address"))
  }

  @Test func redirectHopIntoBenchmarkRangeFollowsWhenConfirmed() async throws {
    // given — the per-hop policy re-runs on redirect targets; a confirmed fake-IP answer on
    // hop 2 is followed like any public address
    let fakeIPAddress = try #require(ResolvedAddress.parse("198.18.0.84"))
    let http = ScriptedHTTP(responses: [
      "https://example.com/start": HTTPResult(
        statusCode: 301,
        headers: ["Location": "https://blog.example/post"],
        body: Data()
      ),
      "https://blog.example/post": htmlResult("<html><body><p>hop two</p></body></html>"),
    ])
    let tool = makeTool(
      http: http,
      resolver: ScriptedResolver(table: [
        "example.com": [publicAddress],
        "blog.example": [fakeIPAddress],
      ]),
      fakeIPDetector: ScriptedFakeIPDetector(detection: .active(sample: fakeIPAddress))
    )

    // when
    let payload = await fetch(tool, url: "https://example.com/start")

    // then
    #expect(payload.status == .ok)
    #expect(payload.content.contains("hop two"))
    #expect(await http.requestedURLs == ["https://example.com/start", "https://blog.example/post"])
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
