import Foundation
import Testing

@testable import ClawWorkspace

@Suite struct WorkspaceDailyLogTests {
  @Test func presentDailyLogLoadsFromMemorySubdirectory() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(
      atRelativePath: "memory/2026-06-29.md",
      content: "today the owner shipped 3a",
      under: root
    )
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.loadDailyLog(day: "2026-06-29", maxGraphemes: nil)

    // then
    #expect(loaded.outcome == .present)
    #expect(loaded.text == "today the owner shipped 3a")
  }

  @Test func missingDailyLogLoadsAsMissing() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.loadDailyLog(day: "2026-06-29", maxGraphemes: nil)

    // then
    #expect(loaded == .missing)
  }

  @Test func malformedDayStemLoadsAsMissingAndCannotTraverse() throws {
    // given - a non YYYY-MM-DD stem, including a traversal attempt, must not read any file.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(atRelativePath: "MEMORY.md", content: "secret", under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let badStem = workspace.loadDailyLog(day: "not-a-date", maxGraphemes: nil)
    let traversal = workspace.loadDailyLog(day: "../../MEMORY", maxGraphemes: nil)

    // then
    #expect(badStem == .missing)
    #expect(traversal == .missing)
  }
}
