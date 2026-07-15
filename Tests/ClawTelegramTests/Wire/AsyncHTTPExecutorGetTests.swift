import AsyncHTTPClient
import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

/// The `get` convenience, which is the one request path the fetch tool takes. The loopback harness
/// it shares with the other wire suites lives in `AsyncHTTPExecutorGeneralRequestTests`.
@Suite(.serialized) struct AsyncHTTPExecutorGetTests {
  private func withNoRedirectExecutor<Result>(
    _ operation: (AsyncHTTPExecutor) async throws -> Result
  ) async throws -> Result {
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    return try await withExecutor(configuration: configuration, operation)
  }

  @Test(.timeLimit(.minutes(1)))
  func getReturnsStatusHeadersAndBody() async throws {
    // given
    try await withScriptedServer(routes: [
      "/page": ScriptedResponse(
        status: .ok,
        headers: [("content-type", "text/html")],
        body: "<html><body>hello</body></html>"
      )
    ]) { server in
      // when
      let result = try await withNoRedirectExecutor { executor in
        try await executor.get(
          url: server.url("/page"),
          headers: [:],
          timeoutSeconds: 5,
          maxBodyBytes: 1024 * 1024
        )
      }

      // then
      #expect(result.statusCode == 200)
      #expect(result.getHeader(for: "Content-Type") == "text/html")
      #expect(String(data: result.body, encoding: .utf8)?.contains("hello") == true)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func disallowConfiguredClientSurfacesRedirectInsteadOfFollowing() async throws {
    // given — the SSRF design turns on this: a redirect must not be followed for us, because only
    // the tool's own gate may decide whether the next hop is a public address.
    try await withScriptedServer(routes: [
      "/hop": ScriptedResponse(
        status: .movedPermanently,
        headers: [("location", "http://127.0.0.1:1/private")],
        body: ""
      )
    ]) { server in
      // when
      let result = try await withNoRedirectExecutor { executor in
        try await executor.get(
          url: server.url("/hop"),
          headers: [:],
          timeoutSeconds: 5,
          maxBodyBytes: 1024
        )
      }

      // then — the redirect came back to us; nothing fetched the Location target
      #expect(result.statusCode == 301)
      #expect(result.getHeader(for: "Location") == "http://127.0.0.1:1/private")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func bodyBeyondMaxBodyBytesIsTruncatedToTheCap() async throws {
    // given
    try await withScriptedServer(routes: [
      "/big": ScriptedResponse(status: .ok, body: String(repeating: "a", count: 4096))
    ]) { server in
      // when
      let result = try await withNoRedirectExecutor { executor in
        try await executor.get(
          url: server.url("/big"),
          headers: [:],
          timeoutSeconds: 5,
          maxBodyBytes: 128
        )
      }

      // then — the cap bounds what is held, and holds it exactly
      #expect(result.body.count == 128)
    }
  }
}
