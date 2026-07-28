import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
import Logging

@testable import ClawLLM

/// The one home for the ChatGPT provider suites' harness and fixtures.
///
/// Namespaced under an enum so its names cannot collide with the file-private `okHead`, `head`,
/// `fixedUUID`, `Fixtures`, and `Harness` that neighboring ChatGPT test files declare for their own
/// seams. Both provider suites — the outcome-parity tests and the cancellation-race tests — drive the
/// provider through this harness so the scripted transport, manual clock, and success fixtures cannot
/// drift between them.
enum ChatGPTProviderTestSupport {
  static func fixedUUID(_ value: String) -> UUID {
    guard let parsed = UUID(uuidString: value) else {
      preconditionFailure("invalid fixed UUID \(value)")
    }
    return parsed
  }

  static let fixedProfileID = fixedUUID("00000000-0000-0000-0000-0000000000AA")
  static let fixedEpoch = fixedUUID("11111111-1111-1111-1111-111111111111")
  static let okHead = HTTPStreamHead(statusCode: 200, headers: [:])

  static func head(_ status: Int, retryAfter: Int? = nil) -> HTTPStreamHead {
    var headers: [String: String] = [:]
    if let retryAfter {
      headers["Retry-After"] = String(retryAfter)
    }
    return HTTPStreamHead(statusCode: status, headers: headers)
  }

  // MARK: - Tool fixtures

  static let clockTool = ToolDefinition(
    name: "clock",
    description: "Read the clock.",
    parameters: .object(["type": .string("object")]),
    egressClass: .none,
    riskLevel: .safe
  )

  static let webFetchTool = ToolDefinition(
    name: "web_fetch",
    description: "Fetch a URL.",
    parameters: .object([
      "type": .string("object"),
      "properties": .object(["url": .object(["type": .string("string")])]),
      "required": .array([.string("url")]),
    ]),
    egressClass: .arbitraryDestination,
    riskLevel: .ask
  )

  // MARK: - Termination inspection

  /// Whether a failure was accounted conservatively and carried the generated deltas as a lower
  /// bound — the model may have been asked, so its tokens are carried rather than written off.
  static func isConservative(_ accounting: ProviderFailureAccounting?) -> Bool {
    guard case .mayHaveStarted(let observed) = accounting else {
      return false
    }
    return observed > 0
  }

  /// The accounting a stream termination carries, or nil when it completed cleanly.
  static func accounting(of terminal: LLMStreamTermination) -> ProviderFailureAccounting? {
    switch terminal {
    case .failed(let failure):
      return failure.accounting
    case .cancelled(let disposition):
      return disposition
    case .completed:
      return nil
    }
  }

  /// The owner-facing message a provider error carries, or nil for the errors that carry none.
  static func message(of failure: ProviderError) -> String? {
    switch failure {
    case .connectFailed(let message):
      return message
    case .retryable(_, let message), .rejected(_, let message), .terminal(_, let message):
      return message
    case .authenticationRequired, .accessDenied, .quotaLimited, .cleanRejection,
      .invalidProviderState, .visionUnsupported:
      return nil
    }
  }

  /// The last `finished` response in a run of parser events, if the stream reached a terminal.
  static func finished(_ events: [StreamEvent]) -> ChatResponse? {
    events.compactMap { event -> ChatResponse? in
      guard case .finished(let response) = event else {
        return nil
      }
      return response
    }
    .last
  }

  static let plainRequest = ChatRequest(
    model: "gpt-5",
    messages: [ChatMessage(role: .user, content: "hello")],
    maxOutputTokens: 256
  )

  static let sessionedRequest = ChatRequest(
    model: "gpt-5",
    messages: [ChatMessage(role: .user, content: "hello")],
    maxOutputTokens: 256,
    sessionId: "sess-1"
  )

  static var defaultCredentials: ScriptedLLMCredentialSource {
    ScriptedLLMCredentialSource(
      headers: ["Authorization": "Bearer test-token"],
      redactionValues: ["test-token"]
    )
  }

  /// The assembled provider over a scripted transport and a manual clock. Every HTTP outcome is a
  /// scripted step and every delay records on the clock, so nothing here waits on real time. Drives
  /// the provider through its internal init so a test can capture the replay-drops diagnostic and
  /// silence logs without widening the pinned public surface.
  struct Harness {
    let http: ScriptedHTTPExecutor
    let provider: ChatGPTResponsesProvider<ScriptedClock>

    init(
      steps: [ScriptedHTTPExecutor.Step],
      credentials: any LLMCredentialSource = ChatGPTProviderTestSupport.defaultCredentials,
      credentialProfileID: UUID? = ChatGPTProviderTestSupport.fixedProfileID,
      retryBudget: Int = 3,
      replayDropsReporter: (@Sendable (ChatGPTReplayDrops) -> Void)? = nil
    ) {
      let http = ScriptedHTTPExecutor(steps)
      self.http = http
      let sleeps = SleepRecorder()
      self.provider = ChatGPTResponsesProvider(
        http: http,
        credentials: credentials,
        credentialProfileID: credentialProfileID,
        buildVersion: "1.2.3-test",
        retryBudget: retryBudget,
        requestTimeoutSeconds: 30,
        clock: ScriptedClock { delay in
          await sleeps.record(delay / .seconds(1))
        },
        jitter: { duration in duration },
        epochID: { ChatGPTProviderTestSupport.fixedEpoch },
        logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() }),
        replayDropsReporter: replayDropsReporter
      )
    }
  }

  /// Scripted SSE bodies for the provider suites. Each `event` is one `data:` frame; the fixtures
  /// assemble the frames a given outcome needs.
  enum Fixtures {
    static func event(_ json: String) -> Data {
      Data("data: \(json)\n\n".utf8)
    }

    /// A minimal success: an announced message, one visible delta, its done item, and a completed
    /// terminal with usage.
    static func basicSuccess() -> [Data] {
      [
        event(
          #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
        ),
        event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
        event(
          #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
        ),
        completedTerminal(),
      ]
    }

    /// Visible text, reasoning replay material, and a tool call — everything a terminal reply carries,
    /// so parity is asserted across every field rather than just the visible content.
    static func richSuccess() -> [Data] {
      [
        event(
          #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
        ),
        event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
        event(
          #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
        ),
        event(
          #"{"type":"response.output_item.added","output_index":1,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC"}}"#
        ),
        event(
          #"{"type":"response.output_item.done","output_index":1,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC"}}"#
        ),
        event(
          #"{"type":"response.output_item.added","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock"}}"#
        ),
        event(
          #"{"type":"response.output_item.done","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock","arguments":"{}"}}"#
        ),
        completedTerminal(),
      ]
    }

    /// A late visible delta arriving after its item has already been declared done.
    static func deltaAfterDone() -> [Data] {
      [
        event(
          #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
        ),
        event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
        event(
          #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
        ),
        event(#"{"type":"response.output_text.delta","output_index":0,"delta":"EXTRA"}"#),
        completedTerminal(),
      ]
    }

    /// Announces an item and emits a delta but never states an outcome, so a consumer that abandons
    /// the iterator mid-stream leaves a turn the model may already have begun.
    static func slowSuccess() -> [Data] {
      [
        event(
          #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
        ),
        event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
      ]
    }

    /// A non-success diagnostic body, carrying an optional error code alongside the message.
    static func errorBody(_ message: String, code: String? = nil) -> [Data] {
      let codeField = code.map { "\"code\":\"\($0)\"," } ?? ""
      return [Data(#"{"error":{\#(codeField)"message":"\#(message)"}}"#.utf8)]
    }

    /// A stream that emits a visible delta and then an in-band error event carrying `code`, so a
    /// mid-stream poisoning after real deltas can be exercised.
    static func dataThenError(code: String) -> [Data] {
      [
        event(
          #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
        ),
        event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
        event(#"{"type":"error","error":{"code":"\#(code)","message":"poisoned"}}"#),
      ]
    }

    static func completedTerminal() -> Data {
      event(
        #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
      )
    }
  }
}
