import ClawCore
import Foundation

public enum SearchError: Error, Sendable, Equatable {
  case terminal(status: Int, message: String)
  case retryable(status: Int, message: String)
  case transport(String)
}

/// The one v1 `SearchProviding` impl (D2 — research-settled). POST /search with `x-api-key`;
/// snippet = highlights[0] → summary → text prefix → "" (§7.4). No internal retries — a failure
/// becomes an observation and the MODEL may re-try, bounded by maxToolCalls.
public struct ExaSearchProvider: SearchProviding {
  public static let defaultEndpoint = "https://api.exa.ai/search"
  static let terminalStatuses: Set<Int> = [400, 401, 402, 403, 404, 409, 422]
  static let snippetTextPrefixGraphemes = 300

  private let apiKey: String
  private let http: any HTTPExecuting
  private let endpoint: String
  private let timeoutSeconds: Int

  public init(
    apiKey: String,
    http: any HTTPExecuting,
    endpoint: String = ExaSearchProvider.defaultEndpoint,
    timeoutSeconds: Int = 15
  ) {
    self.apiKey = apiKey
    self.http = http
    self.endpoint = endpoint
    self.timeoutSeconds = timeoutSeconds
  }

  public func search(query: String, count: Int) async throws -> [SearchResult] {
    let requestBody: [String: Any] = [
      "query": query,
      "numResults": count,
      "moderation": true,
      "contents": ["highlights": true],
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

    let result: HTTPResult
    do {
      result = try await http.post(
        url: endpoint,
        headers: ["x-api-key": apiKey],
        jsonBody: bodyData,
        timeoutSeconds: timeoutSeconds
      )
    } catch {
      throw SearchError.transport(redact("\(error)"))
    }

    guard (200..<300).contains(result.statusCode) else {
      throw classify(status: result.statusCode, body: result.body)
    }

    let decoded: ResponseBody
    do {
      decoded = try JSONDecoder().decode(ResponseBody.self, from: result.body)
    } catch {
      throw SearchError.terminal(status: result.statusCode, message: "malformed search response")
    }

    return decoded.results.map { entry in
      SearchResult(
        title: entry.title ?? entry.url,
        url: entry.url,
        snippet: entry.highlights?.first
          ?? entry.summary
          ?? entry.text.map { text in String(text.prefix(Self.snippetTextPrefixGraphemes)) }
          ?? ""
      )
    }
  }

  // MARK: - Load-bearing

  /// Terminal = 400/401/402/403/404/409/422; retryable-class = 429/500/502/503 (and any other
  /// 5xx, conservatively). Verified against the live Exa error doc 2026-07-03 (spec §7.4).
  private func classify(status: Int, body: Data) -> SearchError {
    let raw = String(data: body, encoding: .utf8) ?? ""
    let message = redact(raw.isEmpty ? "HTTP \(status)" : raw)
    if status == 402 {
      return .terminal(status: 402, message: "search credits exhausted — \(message)")
    }
    if Self.terminalStatuses.contains(status) {
      return .terminal(status: status, message: message)
    }
    return .retryable(status: status, message: message)
  }

  /// The search key joins the exact-value redaction set of its own client (§5).
  private func redact(_ message: String) -> String {
    guard apiKey.isEmpty == false else {
      return message
    }
    return message.replacingOccurrences(of: apiKey, with: "[REDACTED:secret-value]")
  }

  private struct ResponseBody: Decodable {
    struct Entry: Decodable {
      let title: String?
      let url: String
      // swiftlint:disable:next discouraged_optional_collection
      let highlights: [String]?
      let summary: String?
      let text: String?
    }

    let results: [Entry]
  }
}
