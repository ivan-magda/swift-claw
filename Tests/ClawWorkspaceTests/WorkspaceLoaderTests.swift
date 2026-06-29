import Foundation
import Testing

@testable import ClawWorkspace

@Suite struct WorkspaceLoaderTests {
  @Test func missingFileLoadsAsMissingAndNeverThrows() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.load(.memory, maxGraphemes: 2_200)

    // then
    #expect(loaded == .missing)
  }

  @Test func presentFileUnderCapLoadsFullText() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(atRelativePath: "USER.md", content: "owner profile", under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.load(.user, maxGraphemes: 1_375)

    // then
    #expect(loaded.outcome == .present)
    #expect(loaded.text == "owner profile")
    #expect(loaded.graphemeCount == 13)
  }

  @Test func overCapFileReportsOriginalCountButYieldsNoConsumableText() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = String(repeating: "x", count: 10)
    try writeFile(atRelativePath: "MEMORY.md", content: content, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.load(.memory, maxGraphemes: 4)

    // then
    #expect(loaded.outcome == .overCap)
    #expect(loaded.graphemeCount == 10)
    #expect(loaded.text.isEmpty)
  }

  @Test func capCountsGraphemeClustersNotUnicodeScalars() throws {
    // given - each "e\u{0301}" is one grapheme cluster made of two scalars: 4 clusters, 8 scalars.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = String(repeating: "e\u{0301}", count: 4)
    try writeFile(atRelativePath: "MEMORY.md", content: content, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when - cap 5 exceeds the 4 grapheme clusters but is below the 8 scalars.
    let loaded = workspace.load(.memory, maxGraphemes: 5)

    // then - grapheme counting keeps it present; scalar counting would have tripped .overCap.
    #expect(loaded.outcome == .present)
    #expect(loaded.graphemeCount == 4)
    #expect(loaded.text.unicodeScalars.count == 8)
  }

  @Test func nilCapLoadsFullTextRegardlessOfSize() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = String(repeating: "soul ", count: 1_000)
    try writeFile(atRelativePath: "SOUL.md", content: content, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.load(.soul, maxGraphemes: nil)

    // then
    #expect(loaded.outcome == .present)
    #expect(loaded.text == content)
  }

  @Test func presentButUndecodableFileLoadsAsUnreadable() throws {
    // given - invalid UTF-8 bytes force a decode failure on an existing file.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRawFile(atRelativePath: "MEMORY.md", bytes: [0xFF, 0xFF, 0xFF], under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let loaded = workspace.load(.memory, maxGraphemes: 2_200)

    // then - distinct from .missing so Plan 5 can log it (§12), not treat it as a normal empty.
    #expect(loaded.outcome == .unreadable)
    #expect(loaded.text.isEmpty)
    #expect(loaded.graphemeCount == 0)
  }
}
