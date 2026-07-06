import ClawCore
import Foundation
import Testing

@testable import ClawTools

/// Scripted search backend.
struct ScriptedSearch: SearchProviding {
  let results: [SearchResult]
  let thrown: (any Error)?
  let recordedCount: @Sendable (Int) -> Void

  init(
    results: [SearchResult] = [],
    thrown: (any Error)? = nil,
    recordedCount: @escaping @Sendable (Int) -> Void = { _ in }
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

@Suite struct WebSearchToolTests {
  @Test func rendersThePinnedListShapeAndSetsUntrusted() async throws {
    // given
    let tool = WebSearchTool(
      search: ScriptedSearch(results: [
        SearchResult(title: "Swift.org", url: "https://swift.org/", snippet: "The Swift language.")
      ])
    )

    // when
    let payload = await tool.execute(arguments: .object(["query": .string("swift")]))

    // then — "- title — url\n  snippet" (§7.3); snippets are third-party content
    #expect(payload.status == .ok)
    #expect(payload.content == "- Swift.org — https://swift.org/\n  The Swift language.")
    #expect(payload.ingestedUntrusted)
  }

  @Test func countClampsToOneThroughTenAndDefaultsToFive() async throws {
    // given — recordedCount fires synchronously inside each awaited execute, so a lock-guarded
    // box captures the counts in deterministic call order (no detached Tasks to race)
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
      search: ScriptedSearch(recordedCount: { value in box.record(value) })
    )

    // when
    _ = await tool.execute(arguments: .object(["query": .string("q")]))
    _ = await tool.execute(arguments: .object(["query": .string("q"), "count": .number(99)]))
    _ = await tool.execute(arguments: .object(["query": .string("q"), "count": .number(0)]))

    // then
    #expect(box.counts == [5, 10, 1])
  }

  @Test func hugeCountClampsWithoutTrapping() async {
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
      search: ScriptedSearch(recordedCount: { value in box.record(value) })
    )

    // when
    let payload = await tool.execute(
      arguments: .object(["query": .string("q"), "count": .number(1e300)])
    )

    // then — the out-of-range Double clamps to the max instead of trapping on Int(Double)
    #expect(payload.status == .ok)
    #expect(box.counts == [10])
  }

  @Test func backendFailureIsAPlainErrorObservation() async throws {
    // given — v1 tools do not retry internally (§7.4)
    let tool = WebSearchTool(
      search: ScriptedSearch(
        thrown: SearchError.terminal(status: 402, message: "search credits exhausted")
      )
    )

    // when
    let payload = await tool.execute(arguments: .object(["query": .string("q")]))

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("search credits exhausted"))
    #expect(payload.ingestedUntrusted == false)
  }

  @Test func missingQueryIsAnError() async throws {
    // given
    let tool = WebSearchTool(search: ScriptedSearch())

    // when / then
    #expect((await tool.execute(arguments: .object([:]))).status == .error)
  }
}
