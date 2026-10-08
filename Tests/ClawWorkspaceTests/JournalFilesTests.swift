import ClawCore
import ClawWorkspace
import Foundation
import Testing

@Suite
struct JournalFilesTests {
  @Test
  func appendPreservesEditsAndChecksResultingSize() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let day = try #require(JournalDay(isoDate: "2026-10-08"))
    let files = FileSystemJournalFiles(root: root)
    let target = root.appendingPathComponent("memory/2026-10-08.md")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let ownerEditedText = "Owner edit: e\u{0301}"
    try Data(ownerEditedText.utf8).write(to: target)
    let addition = String(
      repeating: "x",
      count: JournalLimits.dayFileBytes - ownerEditedText.utf8.count - 1
    )

    // when
    #expect(throws: JournalFileError.overCap) {
      try files.append(day: day, text: addition + "x")
    }
    #expect(try Data(contentsOf: target) == Data(ownerEditedText.utf8))
    try files.append(day: day, text: addition)
    let afterAppend = try Data(contentsOf: target)
    let beforeRefusedAppend = afterAppend
    #expect(throws: JournalFileError.overCap) {
      try files.append(day: day, text: "я")
    }

    // then
    #expect(afterAppend.starts(with: Data(ownerEditedText.utf8)))
    #expect(afterAppend.count == JournalLimits.dayFileBytes)
    #expect(try Data(contentsOf: target) == beforeRefusedAppend)
    #expect(files.load(day: day).outcome == .present)
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func missingEmptyAndDamagedFilesDoNotRebuildHistory() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let day = try #require(JournalDay(isoDate: "2026-10-08"))
    let files = FileSystemJournalFiles(root: root)
    let target = root.appendingPathComponent("memory/2026-10-08.md")

    // when / then
    #expect(files.load(day: day).outcome == .missing)
    try files.append(day: day, text: "")
    #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    try files.append(day: day, text: "Fresh note\n")
    #expect(files.load(day: day).text == "Fresh note\n")
    try Data([0xFF]).write(to: target)
    #expect(files.load(day: day).outcome == .unreadable)
    #expect(throws: JournalFileError.unreadable) {
      try files.append(day: day, text: "Replacement")
    }
    #expect(try Data(contentsOf: target) == Data([0xFF]))
    try Data(repeating: 0x61, count: JournalLimits.dayFileBytes + 1).write(to: target)
    #expect(files.load(day: day).outcome == .overCap)
    #expect(files.load(day: day).text.isEmpty)
    #expect(throws: JournalFileError.overCap) {
      try files.append(day: day, text: "Replacement")
    }
    try files.delete(day: day)
    try files.delete(day: day)
    #expect(files.load(day: day).outcome == .missing)
  }

  @Test
  func listingAcceptsOnlyContainedValidDayFilesAndDeleteKeepsOtherDays() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileSystemJournalFiles(root: root)
    let today = try #require(JournalDay(isoDate: "2026-10-08"))
    let yesterday = try #require(JournalDay(isoDate: "2026-10-07"))
    try files.append(day: today, text: "Today")
    try files.append(day: yesterday, text: "Yesterday")
    let memory = root.appendingPathComponent("memory")
    try Data().write(to: memory.appendingPathComponent("2026-02-30.md"))
    try FileManager.default.createDirectory(
      at: memory.appendingPathComponent("2026-10-09.md"),
      withIntermediateDirectories: false
    )
    let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: memory.appendingPathComponent("2026-10-10.md"),
      withDestinationURL: outside
    )

    // when / then
    #expect(try files.recentDays(limit: 1) == [today])
    #expect(try files.recentDays(limit: 10) == [today, yesterday])
    #expect(try files.recentDays(limit: 0).isEmpty)
    let escapingDay = try #require(JournalDay(isoDate: "2026-10-10"))
    #expect(files.load(day: escapingDay).outcome == .unreadable)
    #expect(throws: JournalFileError.pathRefused) {
      try files.append(day: escapingDay, text: "Escape")
    }
    #expect(throws: JournalFileError.pathRefused) {
      try files.delete(day: escapingDay)
    }
    #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    try files.delete(day: today)
    #expect(try files.recentDays(limit: 10) == [yesterday])
  }

  @Test
  func sharedMutationGatePreservesConcurrentJournalAppends() async throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileSystemJournalFiles(root: root)
    let day = try #require(JournalDay(isoDate: "2026-10-08"))
    let gate = WorkspaceMutationGate()

    // when
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<32 {
        group.addTask {
          try await gate.perform {
            try files.append(day: day, text: "Note\n")
          }
        }
      }
      try await group.waitForAll()
    }

    // then
    #expect(files.load(day: day).text == String(repeating: "Note\n", count: 32))
  }

}
