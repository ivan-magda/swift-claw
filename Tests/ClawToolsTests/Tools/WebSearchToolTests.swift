import ClawCore
import Foundation
import Testing

@testable import ClawTools

/// Scripted search backend.
struct ScriptedSearch: SearchProviding {
  let results: [SearchResult]
  let thrown: (any Error)?
  let recordedCount: @Sendable (_ count: Int) -> Void

  init(
    results: [SearchResult] = [],
    thrown: (any Error)? = nil,
    recordedCount: @escaping @Sendable (_ count: Int) -> Void = { _ in }
  ) {
    self.results = results
    self.thrown = thrown
    self.recordedCount = recordedCount
  }

  func search(query: String, count: Int) async throws -> [SearchResult] {
    recordedCount(count)
    if let thrown {
      throw thrown
    }
    return results
  }
}

@Suite
struct WebSearchToolTests {
  @Test
  func rendersThePinnedListShapeAndSetsUntrusted() async throws {
    // given
    let tool = WebSearchTool(
      search: ScriptedSearch(results: [
        SearchResult(title: "Swift.org", url: "https://swift.org/", snippet: "The Swift language."),
      ])
    )

    // when
    let payload = await tool.execute(
      arguments: .object(["query": .string("swift")]),
      canonicalTarget: nil
    )

    // then — "- title — url\n  snippet" (§7.3); snippets are third-party content
    #expect(payload.status == .ok)
    #expect(payload.content == "- Swift.org — https://swift.org/\n  The Swift language.")
    #expect(payload.ingestedUntrusted)
  }

  @Test(
    arguments: [
      (requested: nil, sent: 5),
      (requested: 99, sent: 10),
      (requested: 0, sent: 1),
      // an out-of-range Double clamps to the max instead of trapping on Int(Double)
      (requested: 1e300, sent: 10),
    ] as [(requested: Double?, sent: Int)]
  )
  func countClampsToOneThroughTenAndDefaultsToFive(requested: Double?, sent: Int) async {
    // given — recordedCount fires synchronously inside the awaited execute, so a lock-guarded
    // box captures the count without racing (no detached Tasks)
    final class CountBox: @unchecked Sendable {
      private let lock = NSLock()
      private(set) var counts: [Int] = []

      func record(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        counts.append(value)
      }
    }
    let box = CountBox()
    let tool = WebSearchTool(
      search: ScriptedSearch { value in
        box.record(value)
      }
    )
    var arguments: [String: JSONValue] = ["query": .string("q")]
    if let requested {
      arguments["count"] = .number(requested)
    }

    // when
    let payload = await tool.execute(arguments: .object(arguments), canonicalTarget: nil)

    // then
    #expect(payload.status == .ok)
    #expect(box.counts == [sent])
  }

  @Test
  func backendFailureIsAPlainErrorObservation() async throws {
    // given — v1 tools do not retry internally (§7.4)
    let tool = WebSearchTool(
      search: ScriptedSearch(
        thrown: SearchError.terminal(status: 402, message: "search credits exhausted")
      )
    )

    // when
    let payload = await tool.execute(
      arguments: .object(["query": .string("q")]),
      canonicalTarget: nil
    )

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("search credits exhausted"))
    #expect(payload.ingestedUntrusted == false)
  }

  @Test
  func missingQueryIsAnError() async throws {
    // given
    let tool = WebSearchTool(search: ScriptedSearch())

    // when / then
    #expect((await tool.execute(arguments: .object([:]), canonicalTarget: nil)).status == .error)
  }
}
