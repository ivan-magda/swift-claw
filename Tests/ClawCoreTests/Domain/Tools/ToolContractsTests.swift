import Foundation
import Testing

@testable import ClawCore

private struct DefaultPrepareTool: Tool {
  var definition: ToolDefinition {
    ToolDefinition(
      name: "default_prepare",
      description: "test",
      parameters: .object(["type": .string("object")]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe
    )
  }

  var timeout: Duration { .seconds(1) }

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    ToolPayload(content: "ok", status: .ok, ingestedUntrusted: false)
  }
}

@Suite struct ToolContractsTests {
  @Test func jsonValueParsesObjectsAndAccessors() throws {
    // given
    let raw = #"{"url": "https://example.com/a?q=1", "count": 5, "deep": {"flag": true}}"#

    // when
    let parsed = try #require(JSONValue.parse(raw))

    // then
    let object = try #require(parsed.objectValue)
    #expect(object["url"]?.stringValue == "https://example.com/a?q=1")
    #expect(object["count"]?.numberValue == 5)
    #expect(object["deep"]?.objectValue?["flag"] == .bool(true))
  }

  @Test func jsonValuePreservesIntegersBeyondDoublePrecision() throws {
    // given
    let raw = #"{"record_id":9007199254740993}"#

    // when
    let parsed = try #require(JSONValue.parse(raw))
    let encoded = try #require(CanonicalJSON.encode(parsed))

    // then
    #expect(parsed.objectValue?["record_id"] == .integer(9_007_199_254_740_993))
    #expect(encoded == raw)
  }

  @Test func integerAndExactDoubleCasesHaveTheSameJSONNumericValue() {
    // given / when / then
    #expect(JSONValue.integer(5) == .number(5))
    #expect(JSONValue.integer(9_007_199_254_740_993) != .number(9_007_199_254_740_992))
  }

  @Test func jsonValueParseRejectsMalformedJSON() {
    // given / when / then
    #expect(JSONValue.parse(#"{"url": "#) == nil)
    #expect(JSONValue.parse("") == nil)
  }

  @Test func jsonValueEncodesBackToJSON() throws {
    // given
    let value = JSONValue.object([
      "type": .string("object"),
      "required": .array([.string("url")]),
    ])

    // when
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    // then
    #expect(decoded == value)
  }

  @Test func toolCallCodingRoundTripsThePersistedShape() throws {
    // given
    let calls = [
      ToolCall(
        id: "call_1",
        name: "web_fetch",
        argumentsJSON: #"{"url":"https://a.example/x?q=1"}"#
      ),
      ToolCall(id: "call_2", name: "file_read", argumentsJSON: #"{"path":"notes/a.md"}"#),
    ]

    // when
    let encoded = try #require(ToolCallCoding.encode(calls))
    let decoded = ToolCallCoding.decode(encoded)

    // then
    #expect(decoded == calls)
    #expect(encoded.contains(#""arguments""#))  // the pinned column shape
  }

  @Test func toolCallCodingDecodeReturnsEmptyOnMalformedJSON() {
    // given / when / then
    #expect(ToolCallCoding.decode("not json") == [])
    #expect(ToolCallCoding.decode("") == [])
  }

  @Test func observationStampsCallIdentityOntoPayload() {
    // given
    let call = ToolCall(id: "call_9", name: "web_search", argumentsJSON: #"{"query":"swift"}"#)
    let payload = ToolPayload(
      content: "- Swift.org — https://swift.org\n  The Swift language",
      status: .ok,
      ingestedUntrusted: true
    )

    // when
    let observation = ToolObservation(call: call, payload: payload)

    // then
    #expect(observation.callId == "call_9")
    #expect(observation.toolName == "web_search")
    #expect(observation.status == .ok)
    #expect(observation.ingestedUntrusted)
    #expect(observation.readPrivateData == false)
  }

  @Test func observationStatusRawValuesArePinned() {
    // given / when / then — audit rows persist these raw values
    #expect(ToolObservationStatus.ok.rawValue == "ok")
    #expect(ToolObservationStatus.error.rawValue == "error")
    #expect(ToolObservationStatus.blockedArgs.rawValue == "blocked_args")
    #expect(ToolObservationStatus.blockedSSRF.rawValue == "blocked_ssrf")
    #expect(ToolObservationStatus.blockedPendingApproval.rawValue == "blocked_pending_approval")
  }

  @Test func dispatchContextIsAValueType() {
    // given / when — the per-call policy inputs are a Sendable value type (no grant since Inc 5a)
    let context = ToolDispatchContext(
      sessionTainted: true,
      runIngestedUntrusted: false,
      assemblyPrivateData: true,
      runPrivateData: false,
      sessionHasPrivateData: false,
      approvalAlreadyPending: false,
      runOrigin: .interactive
    )

    // then
    #expect(context.sessionTainted)
    #expect(context.approvalAlreadyPending == false)
  }

  @Test func preparedActionCarriesReplacementArgsAndPerCallEgress() {
    // given
    let presentation = ToolApprovalPresentation(
      blastRadius: "run python",
      contentPreview: "print('hello')",
      warnings: []
    )

    // when
    let action = PreparedToolAction(
      canonicalTarget: "code_exec:python:0123456789abcdef",
      canonicalArgsJSON: #"{"code":"print('hello')"}"#,
      presentation: presentation,
      guardTexts: ["print('hello')", "staged text"],
      canExfiltrate: true,
      approvalReason: .codeExec
    )

    // then
    #expect(action.canonicalTarget == "code_exec:python:0123456789abcdef")
    #expect(action.canonicalArgsJSON == #"{"code":"print('hello')"}"#)
    #expect(action.presentation == presentation)
    #expect(action.guardTexts == ["print('hello')", "staged text"])
    #expect(action.canExfiltrate)
    #expect(action.approvalReason == .codeExec)
    #expect(PreparedActionResolution.prepared(action) == .prepared(action))
    #expect(PreparedActionResolution.refused(reason: "no") == .refused(reason: "no"))
  }

  @Test func ordinaryToolsDefaultToNoPreparedAction() async {
    // given
    let tool = DefaultPrepareTool()

    // when
    let resolution = await tool.prepareAction(arguments: .object([:]))

    // then
    #expect(resolution == nil)
  }
}
