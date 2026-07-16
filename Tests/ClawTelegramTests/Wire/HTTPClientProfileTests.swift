import AsyncHTTPClient
import ClawCore
import Foundation
import NIOHTTP1
import Testing

@testable import ClawTelegram

/// A credential on the outbound request, so the refusal below is measured on the kind of request
/// that actually has something to lose. AsyncHTTPClient strips `Authorization` on a hop that leaves
/// the origin and keeps it on one that does not, so what a followed redirect always costs is the
/// choice of who answers — the bearer is what it costs when the hop stays put.
private let sentinelBearer = "Bearer profile-test-sentinel"

/// Where the redirect points, and the only route either server answers with a body.
private let stolenPath = "/stolen"
private let redirectPath = "/redirect"

/// What the redirect target says when it is reached — which only the direct request should ever see.
private let arrivedBody = "arrived"

private func probe(_ url: String) -> HTTPRequest {
  HTTPRequest(
    method: .get,
    url: url,
    headers: ["Authorization": sentinelBearer],
    body: nil,
    timeoutSeconds: 5,
    responseBodyPolicy: .buffered(successBytes: 4096, errorBytes: 4096)
  )
}

@Suite struct HTTPClientProfileTests {
  /// The property the profile exists for. A redirect is an answer, not an instruction: following
  /// one would send this daemon's next request to a host the *response* named.
  @Test func refusesToFollowARedirectToAnotherOrigin() async throws {
    // given — a second origin, ready to record anything that reaches it
    try await withScriptedServer(
      routes: [stolenPath: ScriptedResponse(status: .ok, body: arrivedBody)]
    ) { elsewhere in
      // given — an origin that answers a credential-bearing request by pointing at the second
      try await withScriptedServer(
        routes: [
          redirectPath: ScriptedResponse(
            status: .found,
            headers: [("location", elsewhere.url(stolenPath))]
          )
        ]
      ) { origin in
        // when
        let profile = HTTPClientProfile.protectedEgress.configuration
        let result = try await withExecutor(configuration: profile) { executor in
          try await executor.execute(probe(origin.url(redirectPath)))
        }

        // then — the redirect came back as the answer rather than being taken as a step
        #expect(result.statusCode == 302)
        #expect(elsewhere.recorder.received.isEmpty)

        // then — the request really was made, and really did carry the bearer, so the second
        // origin's silence is a refusal rather than a request that never happened
        #expect(origin.recorder.received.map(\.uri) == [redirectPath])
        #expect(origin.recorder.received.first?.values(for: "authorization") == [sentinelBearer])
      }
    }
  }

  /// The pair to the refusal above. Without it, "the second origin recorded nothing" would be just
  /// as true of an origin that was never reachable or a route that never existed, and the case
  /// above would pass on a client that could not fetch anything at all.
  @Test func reachesTheSameTargetWhenItIsAskedForDirectly() async throws {
    // given — the very server and route the refused redirect pointed at
    try await withScriptedServer(
      routes: [stolenPath: ScriptedResponse(status: .ok, body: arrivedBody)]
    ) { elsewhere in
      // when
      let profile = HTTPClientProfile.protectedEgress.configuration
      let result = try await withExecutor(configuration: profile) { executor in
        try await executor.execute(probe(elsewhere.url(stolenPath)))
      }

      // then
      #expect(result.statusCode == 200)
      #expect(result.body == Data(arrivedBody.utf8))
      #expect(elsewhere.recorder.received.map(\.uri) == [stolenPath])
    }
  }
}
