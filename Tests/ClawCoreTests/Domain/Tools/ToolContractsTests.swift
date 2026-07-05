import Foundation
import Testing

@testable import ClawCore

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

  @Test func dispatchContextAndGrantAreValueTypes() {
    // given
    let grant = OneTurnGrant(
      action: ToolAction(tool: "web_fetch", target: "https://example.com/a?q=1")
    )

    // when
    let context = ToolDispatchContext(
      sessionTainted: true,
      runIngestedUntrusted: false,
      assemblyPrivateData: true,
      runPrivateData: false,
      grant: grant,
      approvalAlreadyPending: false
    )

    // then
    #expect(context.grant == grant)
    let request = ToolApprovalRequest(
      action: ToolAction(tool: "web_fetch", target: "https://x.example/"),
      reason: .exfilTrifecta
    )
    #expect(request.action.target == "https://x.example/")
    #expect(request.reason.rawValue == "exfil_trifecta")
  }
}
