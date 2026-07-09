import ClawCore
import Foundation
import Testing

@testable import ClawTools

/// Scripted POST transport recording the last request for wire assertions.
actor ScriptedPostHTTP: HTTPExecuting {
  private let result: HTTPResult
  private(set) var lastURL: String?
  private(set) var lastHeaders: [String: String] = [:]
  private(set) var lastBody: Data?

  init(result: HTTPResult) {
    self.result = result
  }

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    lastURL = url
    lastHeaders = headers
    lastBody = jsonBody
    return result
  }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    struct GetUnsupported: Error {}
    throw GetUnsupported()
  }
}

@Suite struct ExaSearchProviderTests {
  /// A captured-shape /search response (§20 item 7 — the mapping fixture).
  private static let fixtureBody = #"""
    {
      "requestId": "r1",
      "results": [
        {
          "title": "Swift.org - Welcome",
          "url": "https://swift.org/",
          "highlights": ["Swift is a general-purpose programming language."],
          "text": "full page text here"
        },
        {
          "title": "Swift Forums",
          "url": "https://forums.swift.org/",
          "summary": "Community discussion for Swift."
        },
        {
          "title": "Bare Result",
          "url": "https://example.com/bare"
        }
      ]
    }
    """#

  @Test func mapsResultsWithThePinnedSnippetFallback() async throws {
    // given
    let http = ScriptedPostHTTP(
      result: HTTPResult(statusCode: 200, headers: [:], body: Data(Self.fixtureBody.utf8))
    )
    let provider = ExaSearchProvider(apiKey: "exa-key", http: http)

    // when
    let results = try await provider.search(query: "swift language", count: 3)

    // then — highlights[0] → summary → "" (§7.4)
    #expect(results.count == 3)
    #expect(results[0].snippet == "Swift is a general-purpose programming language.")
    #expect(results[1].snippet == "Community discussion for Swift.")
    #expect(results[2].snippet.isEmpty)
    #expect(results[0].url == "https://swift.org/")

    // and the wire request is the pinned shape
    #expect(await http.lastURL == "https://api.exa.ai/search")
    #expect(await http.lastHeaders["x-api-key"] == "exa-key")
    let body =
      try JSONSerialization.jsonObject(with: #require(await http.lastBody)) as? [String: Any]
    #expect(body?["query"] as? String == "swift language")
    #expect(body?["numResults"] as? Int == 3)
    #expect(body?["moderation"] as? Bool == true)
    #expect((body?["contents"] as? [String: Any])?["highlights"] as? Bool == true)
  }

  @Test func fourOhTwoIsTerminalWithTheCreditsMessage() async throws {
    // given — 402 = credits exhausted (verified live 2026-07-03)
    let http = ScriptedPostHTTP(
      result: HTTPResult(statusCode: 402, headers: [:], body: Data(#"{"error":"no credits"}"#.utf8))
    )
    let provider = ExaSearchProvider(apiKey: "exa-key", http: http)

    // when / then
    await #expect {
      _ = try await provider.search(query: "q", count: 5)
    } throws: { thrown in
      guard case SearchError.terminal(let status, let message) = thrown else {
        return false
      }
      return status == 402 && message.contains("search credits exhausted")
    }
  }

  @Test func retryableStatusesClassifyAsRetryable() async throws {
    // given
    let http = ScriptedPostHTTP(
      result: HTTPResult(statusCode: 503, headers: [:], body: Data())
    )
    let provider = ExaSearchProvider(apiKey: "exa-key", http: http)

    // when / then
    await #expect {
      _ = try await provider.search(query: "q", count: 5)
    } throws: { thrown in
      guard case SearchError.retryable(let status, _) = thrown else {
        return false
      }
      return status == 503
    }
  }

  @Test func errorMessagesNeverEchoTheKey() async throws {
    // given — an error body that reflects the key back
    let http = ScriptedPostHTTP(
      result: HTTPResult(
        statusCode: 401,
        headers: [:],
        body: Data(#"{"error":"bad key exa-key"}"#.utf8)
      )
    )
    let provider = ExaSearchProvider(apiKey: "exa-key", http: http)

    // when / then
    await #expect {
      _ = try await provider.search(query: "q", count: 5)
    } throws: { thrown in
      guard case SearchError.terminal(_, let message) = thrown else {
        return false
      }
      return message.contains("exa-key") == false
    }
  }
}
