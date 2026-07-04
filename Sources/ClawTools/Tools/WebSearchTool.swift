import ClawCore
import Foundation

/// Thin wrapper over `SearchProviding` (§7.3). The query egresses to the owner-pinned search
/// endpoint (trusted-egress class, §18-H): covered by the arg guard, not the trifecta approval.
public struct WebSearchTool: Tool {
  static let defaultCount = 5
  static let countRange = 1...10

  private let search: any SearchProviding
  private let outputCapGraphemes: Int

  public init(search: any SearchProviding, outputCapGraphemes: Int = ToolOutputCap.maxGraphemes) {
    self.search = search
    self.outputCapGraphemes = outputCapGraphemes
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "web_search",
      description: "Search the public web. Returns titles, URLs, and snippets.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "query": .object([
            "type": .string("string"),
            "description": .string("The search query."),
          ]),
          "count": .object([
            "type": .string("number"),
            "description": .string("How many results (1-10, default 5)."),
          ]),
        ]),
        "required": .array([.string("query")]),
      ])
    )
  }

  public var timeout: Duration { .seconds(15) }

  public func execute(arguments: JSONValue) async -> ToolPayload {
    guard
      let query = arguments.objectValue?["query"]?.stringValue,
      query.isEmpty == false
    else {
      return ToolPayload(
        content: "web_search needs a non-empty \"query\" argument.",
        status: .error,
        ingestedUntrusted: false
      )
    }

    let requestedCount =
      arguments.objectValue?["count"]?.numberValue
      .map { requested in
        Int(
          min(
            max(requested, Double(Self.countRange.lowerBound)),
            Double(Self.countRange.upperBound)
          )
        )
      } ?? Self.defaultCount
    let count = min(
      max(requestedCount, Self.countRange.lowerBound),
      Self.countRange.upperBound
    )

    let results: [SearchResult]
    do {
      results = try await search.search(query: query, count: count)
    } catch let searchError as SearchError {
      let reason =
        switch searchError {
        case .terminal(_, let message), .retryable(_, let message):
          message
        case .transport(let message):
          message
        }
      return ToolPayload(
        content: "Search failed: \(reason)",
        status: .error,
        ingestedUntrusted: false
      )
    } catch {
      return ToolPayload(
        content: "Search failed unexpectedly.",
        status: .error,
        ingestedUntrusted: false
      )
    }

    guard results.isEmpty == false else {
      return ToolPayload(content: "No results.", status: .ok, ingestedUntrusted: true)
    }

    let rendered = results.map { result in
      "- \(result.title) — \(result.url)\n  \(result.snippet)"
    }.joined(separator: "\n")

    return ToolPayload(
      content: ToolOutputCap.cap(rendered, maxGraphemes: outputCapGraphemes),
      status: .ok,
      ingestedUntrusted: true  // snippets are third-party content
    )
  }
}
