import Foundation
import Testing

@testable import ClawCore

@Suite struct WorkspaceValuesTests {
  @Test func workspaceFileRelativePathsMatchKnownFilenames() {
    // given / when / then
    #expect(WorkspaceFile.soul.relativePath == "SOUL.md")
    #expect(WorkspaceFile.agents.relativePath == "AGENTS.md")
    #expect(WorkspaceFile.tools.relativePath == "TOOLS.md")
    #expect(WorkspaceFile.user.relativePath == "USER.md")
    #expect(WorkspaceFile.memory.relativePath == "MEMORY.md")
    #expect(WorkspaceFile.heartbeat.relativePath == "HEARTBEAT.md")
  }

  @Test func workspaceFileEnumeratesEveryFixedFileInOrder() {
    // given / when
    let paths = WorkspaceFile.allCases.map(\.relativePath)

    // then
    #expect(paths == ["SOUL.md", "AGENTS.md", "TOOLS.md", "USER.md", "MEMORY.md", "HEARTBEAT.md"])
  }

  @Test func everyPromptSteeringFileIsPrivilegedIncludingSkillManifests() {
    // given / when / then — a write to any of these feeds a later turn, so all earn the banner.
    for file in WorkspaceFile.allCases {
      #expect(WorkspaceFile.isPromptPrivileged(basename: file.relativePath))
    }
    #expect(WorkspaceFile.isPromptPrivileged(basename: "SKILL.md"))
    #expect(WorkspaceFile.isPromptPrivileged(basename: "notes.md") == false)
    #expect(WorkspaceFile.isPromptPrivileged(basename: "skill.md") == false)
  }

  @Test func missingLoadedFileIsEmptyZeroLengthWithMissingOutcome() {
    // given / when
    let missing = LoadedFile.missing

    // then
    #expect(missing.outcome == .missing)
    #expect(missing.text.isEmpty)
    #expect(missing.graphemeCount == 0)
  }
}
