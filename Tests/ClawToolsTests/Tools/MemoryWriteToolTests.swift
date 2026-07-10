import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct MemoryWriteToolTests {
  private let tool = MemoryWriteTool(redactor: SecretRedactor(secretValues: []))

  private func arguments(_ json: String) -> JSONValue {
    JSONValue.parse(json) ?? .null
  }

  @Test func declaresAskTierWithNoEgress() {
    // given / when / then
    #expect(tool.definition.name == "memory_write")
    #expect(tool.definition.riskLevel == .ask)
    #expect(tool.definition.egressClass == .none)
  }

  @Test func canonicalTargetIsTheKindAndHash16OfTheNormalizedText() throws {
    // given
    let callArguments = arguments(#"{"text":"prefers metric units","kind":"user"}"#)
    guard
      case .parsed(let request) = MemoryWriteArguments.parse(callArguments, sessionId: nil)
    else {
      Issue.record("parse failed")
      return
    }

    // when
    let resolution = tool.canonicalTarget(arguments: callArguments)

    // then — identical derivation to the shared decoder (one source of truth)
    #expect(resolution == .resolved(MemoryWriteArguments.canonicalTarget(for: request)))
  }

  @Test func malformedArgumentsRefuseAtGateTime() {
    // given / when / then
    guard case .refused = tool.canonicalTarget(arguments: arguments(#"{"kind":"user"}"#)) else {
      Issue.record("expected a refusal for missing text")
      return
    }
  }

  @Test func presentationCarriesScanWarningsAndTheVerbatimCappedPreview() throws {
    // given — secret-shaped text: the §8.2 preview is VERBATIM (the owner judges exactly what
    // would be stored); the scan warning flags it instead of hiding it
    let callArguments = arguments(#"{"text":"the api_key is on the desk","kind":"reference"}"#)
    let target = "memory_item:reference:0000000000000000"

    // when
    let presentation = tool.approvalPresentation(
      arguments: callArguments,
      canonicalTarget: target
    )

    // then
    #expect(presentation.contentPreview == "the api_key is on the desk")
    #expect(presentation.warnings == ["possible secret-shaped text"])
    #expect(presentation.blastRadius.contains("kind reference"))
    #expect(presentation.blastRadius.contains("sensitivity normal"))
  }

  @Test func presentationRedactsConfiguredSecretValuesFromThePreview() {
    // given — the proposed text embeds an exact loaded secret (§12: exact-value redaction at the
    // outbound-reply boundary); the preview is otherwise verbatim
    let redactingTool = MemoryWriteTool(
      redactor: SecretRedactor(secretValues: ["tg-bot-token-123"])
    )
    let callArguments = arguments(
      #"{"text":"the bot token is tg-bot-token-123 on the pi","kind":"reference"}"#
    )

    // when
    let presentation = redactingTool.approvalPresentation(
      arguments: callArguments,
      canonicalTarget: "memory_item:reference:0000000000000000"
    )

    // then
    #expect(
      presentation.contentPreview
        == "the bot token is \(SecretRedactor.replacement) on the pi"
    )
  }

  @Test func executeIsAFailClosedStubOffTheApprovalPath() async {
    // given / when — ask-tier means the gate never allows a direct dispatch (§4.3); the real
    // insert is the waiter's fused transaction (§6.3)
    let payload = await tool.execute(
      arguments: arguments(#"{"text":"x","kind":"user"}"#),
      canonicalTarget: nil
    )

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("approval"))
  }
}
