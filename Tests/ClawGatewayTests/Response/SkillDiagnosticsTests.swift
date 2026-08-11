import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct SkillDiagnosticsTests {
  @Test func renderIncludesAcceptedDescriptorsAndEveryRejectedWarning() throws {
    // given
    let scan = SkillScanResult(
      descriptors: [
        descriptor(name: "alpha", description: "First skill."),
        descriptor(name: "bravo", description: "Second skill."),
      ],
      warnings: [
        .invalidSkillManifest(skill: "broken"),
        .invalidSkillName(directory: "Shouting", name: "Shouting"),
        .skillNameDirectoryMismatch(directory: "triage", name: "triage-mail"),
        .duplicateSkillName(name: "deploy", directories: ["deploy", "deploy-copy"]),
        .escapingSkillDirectory(directory: "linked-out"),
        .unreadableSkillsDirectory,
        .skillsDirectoryOutsideWorkspace,
      ]
    )
    let diagnostics = SkillDiagnostics(scan: scan, skillsCap: 4_000)

    // when
    let rendered = diagnostics.render()

    // then
    #expect(diagnostics.acceptedCount == 2)
    #expect(diagnostics.rejectedCount == 7)
    #expect(rendered.contains("Accepted (2)"))
    let acceptedRange = try #require(rendered.range(of: "Accepted (2)"))
    let rejectedRange = try #require(rendered.range(of: "Rejected (7)"))
    #expect(acceptedRange.lowerBound < rejectedRange.lowerBound)
    for descriptor in scan.descriptors {
      #expect(rendered.contains(WorkspaceSkills.indexLine(for: descriptor)))
    }
    #expect(rendered.contains("Rejected (7)"))
    for warning in scan.warnings {
      #expect(rendered.contains(warning.ownerFacingReason))
    }
  }

  @Test func duplicateWarningNamesEveryClaimant() {
    // given
    let warning = WorkspaceWarning.duplicateSkillName(
      name: "deploy",
      directories: ["deploy", "deploy-copy"]
    )
    let diagnostics = SkillDiagnostics(
      scan: SkillScanResult(descriptors: [], warnings: [warning]),
      skillsCap: 4_000
    )

    // when
    let rendered = diagnostics.render()

    // then
    #expect(rendered.contains("`deploy`"))
    #expect(rendered.contains("`deploy-copy`"))
    #expect(rendered.contains("all of them skipped"))
  }

  @Test func emptyScanRendersExplicitEmptySections() {
    // given
    let diagnostics = SkillDiagnostics(
      scan: SkillScanResult(descriptors: [], warnings: []),
      skillsCap: 0
    )

    // when
    let rendered = diagnostics.render()

    // then
    #expect(diagnostics.acceptedCount == 0)
    #expect(diagnostics.rejectedCount == 0)
    #expect(diagnostics.completeIndexGraphemes == 0)
    #expect(diagnostics.fitsSkillsCap)
    #expect(rendered.contains("Accepted (0)\nNone."))
    #expect(rendered.contains("Rejected (0)\nNone."))
  }

  @Test func completeIndexEqualToTheCapFits() {
    // given
    let scan = SkillScanResult(
      descriptors: [descriptor(name: "emoji", description: "Family 👨‍👩‍👧‍👦")],
      warnings: []
    )
    let exactCap = WorkspaceSkills.completeIndexGraphemeCount(for: scan.descriptors)

    // when
    let diagnostics = SkillDiagnostics(scan: scan, skillsCap: exactCap)

    // then
    #expect(diagnostics.completeIndexGraphemes == exactCap)
    #expect(diagnostics.fitsSkillsCap)
  }

  @Test func completeIndexOneGraphemeOverTheCapDoesNotFit() {
    // given
    let scan = SkillScanResult(
      descriptors: [descriptor(name: "emoji", description: "Family 👨‍👩‍👧‍👦")],
      warnings: []
    )
    let indexCount = WorkspaceSkills.completeIndexGraphemeCount(for: scan.descriptors)

    // when
    let diagnostics = SkillDiagnostics(scan: scan, skillsCap: indexCount - 1)

    // then
    #expect(diagnostics.completeIndexGraphemes == diagnostics.skillsCap + 1)
    #expect(diagnostics.fitsSkillsCap == false)
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
