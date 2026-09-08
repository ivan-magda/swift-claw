import ClawCore
import Foundation
import Testing

@testable import clawd

@Suite("Skill diagnostics composition")
struct SkillDiagnosticsCompositionTests {
  @Test("daemon health scans the workspace again for every report")
  func freshWorkspaceScanReachesHealthReport() async throws {
    // given
    let harness = try await CompositionAcceptanceHarness.boot(
      environment: CompositionAcceptanceHarness.validEnv()
    )
    defer { try? FileManager.default.removeItem(at: harness.config.stateRoot) }
    let workspaceRoot = EnvironmentLoader.workspaceRoot(config: harness.config)
    let skillDirectory =
      workspaceRoot
      .appendingPathComponent(WorkspaceSkills.directoryName, isDirectory: true)
      .appendingPathComponent("summarize", isDirectory: true)

    // when
    let before = harness.healthRow("context.skills")
    try FileManager.default.createDirectory(
      at: skillDirectory,
      withIntermediateDirectories: true
    )
    let manifest = """
      ---
      name: summarize
      description: Summarize owner-provided text.
      ---
      Follow the owner's requested summary format.
      """
    try Data(manifest.utf8).write(
      to: skillDirectory.appendingPathComponent(WorkspaceSkills.manifestName)
    )
    let after = await harness.freshHealthRows()["context.skills"]

    // then
    #expect(before?.contains("accepted=0") == true)
    #expect(after?.contains("accepted=1") == true)
    #expect(after?.contains("rejected=0") == true)
  }
}
