import Foundation
import Testing

@testable import ClawWorkspace

@Suite struct WorkspaceValuesTests {
  @Test func workspaceFileRelativePathsMatchKnownFilenames() {
    // given / when / then
    #expect(WorkspaceFile.soul.relativePath == "SOUL.md")
    #expect(WorkspaceFile.agents.relativePath == "AGENTS.md")
    #expect(WorkspaceFile.tools.relativePath == "TOOLS.md")
    #expect(WorkspaceFile.user.relativePath == "USER.md")
    #expect(WorkspaceFile.memory.relativePath == "MEMORY.md")
  }

  @Test func workspaceFileEnumeratesEveryFixedFileInOrder() {
    // given / when
    let paths = WorkspaceFile.allCases.map(\.relativePath)

    // then
    #expect(paths == ["SOUL.md", "AGENTS.md", "TOOLS.md", "USER.md", "MEMORY.md"])
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
