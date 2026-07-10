import Foundation
import Testing

@testable import ClawCore

@Suite struct MemoryWriteArgumentsTests {
  private func arguments(_ json: String) -> JSONValue {
    JSONValue.parse(json) ?? .null
  }

  @Test func parseBuildsAnAssistantSourcedItemWithDefaults() throws {
    // given / when
    let outcome = MemoryWriteArguments.parse(
      arguments(#"{"text":"prefers metric units","kind":"user"}"#),
      sessionId: 9
    )

    // then — source is ALWAYS .assistant on this path; importance/sensitivity default .normal
    guard case .parsed(let request) = outcome else {
      Issue.record("expected .parsed, got \(outcome)")
      return
    }
    #expect(request.item.source == .assistant)
    #expect(request.item.kind == .user)
    #expect(request.item.importance == .normal)
    #expect(request.item.sensitivity == .normal)
    #expect(request.item.sessionId == 9)
  }

  @Test func parseMapsImportanceAndSensitivityLabels() throws {
    // given / when
    let outcome = MemoryWriteArguments.parse(
      arguments(
        #"{"text":"ship friday","kind":"project","importance":"high","sensitivity":"high"}"#
      ),
      sessionId: nil
    )

    // then
    guard case .parsed(let request) = outcome else {
      Issue.record("expected .parsed, got \(outcome)")
      return
    }
    #expect(request.item.importance == .high)
    #expect(request.item.sensitivity == .high)
  }

  @Test(arguments: [
    #"{"kind":"user"}"#,
    #"{"text":"","kind":"user"}"#,
    #"{"text":"x","kind":"diary"}"#,
    #"{"text":"x","kind":"user","importance":"critical"}"#,
    #"{"text":"x","kind":"user","sensitivity":"secret"}"#,
  ])
  func malformedArgumentsAreInvalid(_ json: String) {
    // given / when / then — fail closed on every unrecognized field value
    guard case .invalid = MemoryWriteArguments.parse(arguments(json), sessionId: nil) else {
      Issue.record("expected .invalid for \(json)")
      return
    }
  }

  @Test func canonicalTargetHashesTheNormalizedTextNotTheRawText() throws {
    // given — the same fact, once with zero-width smuggling; normalization strips it (§8.2)
    let plain = MemoryWriteArguments.parse(
      arguments(#"{"text":"prefers metric units","kind":"user"}"#),
      sessionId: nil
    )
    let smuggled = MemoryWriteArguments.parse(
      arguments(#"{"text":"prefers metric\#u{200B} units","kind":"user"}"#),
      sessionId: nil
    )
    guard case .parsed(let plainRequest) = plain, case .parsed(let smuggledRequest) = smuggled
    else {
      Issue.record("parse failed")
      return
    }

    // when
    let plainTarget = MemoryWriteArguments.canonicalTarget(for: plainRequest)
    let smuggledTarget = MemoryWriteArguments.canonicalTarget(for: smuggledRequest)

    // then — "memory_item:<kind>:<hash16>": 16 hex over the NORMALIZED stored text
    #expect(plainTarget == smuggledTarget)
    #expect(plainTarget.hasPrefix("memory_item:user:"))
    let hash16 = plainTarget.split(separator: ":").last.map(String.init) ?? ""
    #expect(hash16.count == 16)
    try #expect(hash16.allSatisfy(\.isHexDigit))
  }

  @Test func assistantSourceRawValueIsStable() {
    // given / when / then — the durable memory_items.source vocabulary
    #expect(MemorySource.assistant.rawValue == "assistant")
    #expect(MemorySource.owner.rawValue == "owner")
  }
}
