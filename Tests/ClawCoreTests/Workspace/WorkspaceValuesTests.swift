import Foundation
import Testing

@testable import ClawCore

@Suite
struct WorkspaceValuesTests {
  @Test
  func workspaceFileEnumeratesEveryFixedFileInOrder() {
    // given / when
    let paths = WorkspaceFile.allCases.map(\.relativePath)

    // then
    #expect(paths == ["SOUL.md", "AGENTS.md", "TOOLS.md", "USER.md", "MEMORY.md", "HEARTBEAT.md"])
  }

  @Test
  func everyPromptSteeringFileIsPrivilegedIncludingSkillManifests() {
    // given / when / then — a write to any of these feeds a later turn, so all earn the banner.
    for file in WorkspaceFile.allCases {
      #expect(WorkspaceFile.isPromptPrivileged(basename: file.relativePath))
    }
    #expect(WorkspaceFile.isPromptPrivileged(basename: "SKILL.md"))
    #expect(WorkspaceFile.isPromptPrivileged(basename: "notes.md") == false)
    #expect(WorkspaceFile.isPromptPrivileged(basename: "2026-10-08.md") == false)
    // A case-insensitive filesystem indexes `skill.md` as a skill, and a creating write carries the
    // caller's own spelling, so a lowercase manifest must not slip past the banner.
    #expect(WorkspaceFile.isPromptPrivileged(basename: "skill.md"))
    #expect(WorkspaceFile.isPromptPrivileged(basename: "soul.md"))
  }

  @Test(arguments: [
    ("memory/2026-10-08.md", true),
    ("reports/2026-10-08.md", false),
    ("memory/nested/2026-10-08.md", false),
    ("memory/2026-02-30.md", false),
    ("memory/2026-10-08.txt", false),
  ])
  func datedJournalUsesSharedPrivateClassification(path: String, expected: Bool) {
    // given / when / then
    #expect(
      WorkspaceFile.isPrivateData(
        canonicalPath: "/workspace/" + path,
        canonicalRoot: "/workspace"
      ) == expected
    )
  }
}
