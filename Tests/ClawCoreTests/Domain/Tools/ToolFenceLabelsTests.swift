import Foundation
import Testing

@testable import ClawCore

@Suite struct ToolFenceLabelsTests {
  private func definition(name: String, fenceLabel: String? = nil) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: "d",
      parameters: .object(["type": .string("object")]),
      egressClass: .none,
      riskLevel: .safe,
      fenceLabel: fenceLabel
    )
  }

  @Test func anUndeclaredLabelDefaultsToTheToolName() {
    // given / when
    let undeclared = definition(name: "web_fetch")

    // then
    #expect(undeclared.fenceLabel == "web_fetch")
  }

  @Test func aDeclaredLabelResolvesForItsToolAndOnlyItsTool() {
    // given
    let labels = ToolFenceLabels(
      definitions: [definition(name: "skill_load", fenceLabel: "skills"), definition(name: "cat")]
    )

    // when / then
    #expect(labels.label(forToolNamed: "skill_load") == "skills")
    #expect(labels.label(forToolNamed: "cat") == "cat")
  }

  @Test func anUnknownToolNameFallsBackToItself() {
    // given — history can replay a tool that is no longer registered
    let labels = ToolFenceLabels(definitions: [definition(name: "skill_load", fenceLabel: "skills")]
    )

    // when / then
    #expect(labels.label(forToolNamed: "web_fetch") == "web_fetch")
    #expect(ToolFenceLabels.toolNames.label(forToolNamed: "skill_load") == "skill_load")
  }
}
