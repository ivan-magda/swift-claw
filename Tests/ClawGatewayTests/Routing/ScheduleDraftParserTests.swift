import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ScheduleDraftParserTests {
  private func jsonResponse(_ content: String) -> ChatResponse {
    ChatResponse(content: content, finishReason: "stop", usage: nil, costFromProvider: nil)
  }

  private static let draftJSON = """
    {"label":"morning digest","prompt":"Summarize my unread items",\
    "schedule":{"kind":"weekdays","time":"07:00","timezone":"Europe/Berlin"}}
    """

  private static let expectedDraft = ScheduleDraft(
    label: "morning digest",
    prompt: "Summarize my unread items",
    schedule: DraftSchedule(kind: .weekdays, time: "07:00", timezone: "Europe/Berlin")
  )

  @Test func decodesASingleJSONObjectIntoADraft() async {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let parser = ScheduleDraftParser(provider: provider, model: "test-model")

    // when
    let result = await parser.parse(ownerText: "every weekday at 7am Berlin, summarize unread")

    // then
    #expect(result == .draft(Self.expectedDraft))
  }

  @Test func sendsOneBoundedSystemPromptedRequestWithOwnerTextAsData() async throws {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let parser = ScheduleDraftParser(provider: provider, model: "test-model")

    // when
    _ = await parser.parse(ownerText: "every weekday at 7am")

    // then — one call; system-authored prompt first; owner text is a plain user message; no
    // tools; the pinned output cap bounds the call in place of a preflight
    let requests = await provider.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.model == "test-model")
    #expect(request.messages.count == 2)
    #expect(request.messages[0].role == .system)
    #expect(request.messages[0].content == ScheduleDraftParser.systemPrompt)
    #expect(request.messages[1].role == .user)
    #expect(request.messages[1].content == "every weekday at 7am")
    #expect(request.tools.isEmpty)
    #expect(request.maxOutputTokens == ScheduleDraftParser.maxParseOutputTokens)
  }

  @Test func stripsAStrayCodeFenceBeforeDecoding() async {
    // given — models fence JSON despite instructions; the fence is cosmetic, not schema
    let fenced = "```json\n\(Self.draftJSON)\n```"
    let provider = SequenceProvider([jsonResponse(fenced)])
    let parser = ScheduleDraftParser(provider: provider, model: "test-model")

    // when / then
    #expect(await parser.parse(ownerText: "x") == .draft(Self.expectedDraft))
  }

  @Test func rejectsNonJSONAndUnknownEnumValues() async {
    // given / when / then — strict decode: no guessing, no partial acceptance
    #expect(ScheduleDraftParser.decode("UNPARSEABLE") == .unparseable)
    #expect(ScheduleDraftParser.decode("Sure! Here is the plan…") == .unparseable)
    #expect(ScheduleDraftParser.decode("") == .unparseable)
    let badKind = """
      {"label":"x","prompt":"y","schedule":{"kind":"fortnightly","time":"07:00"}}
      """
    #expect(ScheduleDraftParser.decode(badKind) == .unparseable)
  }

  @Test func providerFailureDegradesWithoutArming() async {
    // given — an empty script makes SequenceProvider throw a terminal ProviderError
    let provider = SequenceProvider([])
    let parser = ScheduleDraftParser(provider: provider, model: "test-model")

    // when / then
    #expect(await parser.parse(ownerText: "x") == .providerUnavailable)
  }
}
