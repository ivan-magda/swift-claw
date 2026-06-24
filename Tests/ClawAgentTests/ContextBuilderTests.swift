import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite("ContextBuilder")
struct ContextBuilderTests {
  @Test("keeps the system prompt and drops the oldest history to fit the cap")
  func keepsSystemPromptAndDropsOldestHistoryToFit() throws {
    // given — cap 11 minus a 3-grapheme prompt leaves 8 graphemes; two 4-grapheme messages fit.
    let history = [userMessage("aaaa"), userMessage("bbbb"), userMessage("cccc")]

    // when
    let result = ContextBuilder.assemble(
      systemPrompt: "Sys",
      history: history,
      inputCapGraphemes: 11
    )

    // then — oldest "aaaa" dropped; survivors stay chronological; marker on the system prompt.
    let systemMessage = try #require(result.first)
    #expect(systemMessage.role == .system)
    #expect(systemMessage.content.contains("[…earlier conversation truncated]"))
    #expect(result.dropFirst().map(\.content) == ["bbbb", "cccc"])
  }

  @Test("the system prompt is never dropped even when it alone exceeds the cap")
  func systemPromptIsNeverDroppedEvenWhenOverCap() throws {
    // given
    let systemPrompt = "A very long system prompt that alone exceeds the cap"

    // when
    let result = ContextBuilder.assemble(
      systemPrompt: systemPrompt,
      history: [],
      inputCapGraphemes: 1
    )

    // then — exactly the system message, unchanged (no history was dropped → no marker).
    #expect(result.count == 1)
    let systemMessage = try #require(result.first)
    #expect(systemMessage.role == .system)
    #expect(systemMessage.content == systemPrompt)
  }
}
