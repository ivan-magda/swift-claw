import Foundation
import Testing

@testable import ClawCore

@Suite struct SkillDiagnosticsTests {
  @Test func canonicalIndexUsesOneLinePerDescriptorAndCountsGraphemes() {
    // given
    let descriptors = [
      descriptor(name: "alpha", description: "First skill."),
      descriptor(name: "emoji", description: "One family 👨‍👩‍👧‍👦."),
    ]

    // when
    let index = WorkspaceSkills.completeIndex(for: descriptors)
    let count = WorkspaceSkills.completeIndexGraphemeCount(for: descriptors)

    // then
    #expect(
      index == """
        - alpha: First skill.
        - emoji: One family 👨‍👩‍👧‍👦.
        """
    )
    #expect(count == index.count)
    #expect(WorkspaceSkills.indexLine(for: descriptors[0]) == "- alpha: First skill.")
  }

  @Test func emptyDescriptorListHasAnEmptyZeroLengthIndex() {
    // given
    let descriptors: [SkillDescriptor] = []

    // when
    let index = WorkspaceSkills.completeIndex(for: descriptors)

    // then
    #expect(index.isEmpty)
    #expect(WorkspaceSkills.completeIndexGraphemeCount(for: descriptors) == 0)
  }

  @Test(
    arguments: [
      (
        WorkspaceWarning.invalidSkillManifest(skill: "broken"),
        "Skill `broken`",
        "frontmatter"
      ),
      (
        WorkspaceWarning.invalidSkillName(directory: "Shouting", name: "Shouting"),
        "Skill `Shouting`",
        "lowercase"
      ),
      (
        WorkspaceWarning.skillNameDirectoryMismatch(directory: "triage", name: "triage-mail"),
        "Skill `triage`",
        "`triage-mail`"
      ),
      (
        WorkspaceWarning.duplicateSkillName(
          name: "deploy",
          directories: ["deploy", "deploy-copy"]
        ),
        "Skill name `deploy`",
        "`deploy-copy`"
      ),
      (
        WorkspaceWarning.escapingSkillDirectory(directory: "linked-out"),
        "Skill `linked-out`",
        "outside the workspace"
      ),
      (
        WorkspaceWarning.unreadableSkillsDirectory,
        "`skills` directory",
        "couldn't be read"
      ),
      (
        WorkspaceWarning.skillsDirectoryOutsideWorkspace,
        "`skills` directory",
        "outside the workspace"
      ),
    ]
  )
  func everyWarningHasAnOwnerFacingReason(
    warning: WorkspaceWarning,
    identity: String,
    explanation: String
  ) {
    // given / when
    let reason = warning.ownerFacingReason

    // then
    #expect(reason.contains(identity))
    #expect(reason.contains(explanation))
    #expect(reason.contains("skipped"))
  }
}

private extension SkillDiagnosticsTests {
  func descriptor(name: String, description: String) -> SkillDescriptor {
    SkillDescriptor(
      name: name,
      description: description,
      directory: URL(fileURLWithPath: "/tmp/skills/\(name)")
    )
  }
}
