import ClawCore
import Foundation
import Logging
import Synchronization
import Testing

@testable import ClawGateway

/// Captures the notices an echo enqueues and the pokes it fires. Synchronous by design: both
/// seams are non-async, so a lock keeps "what the owner would have been told" readable without an
/// actor hop that would blur the ordering the echo contract is about.
private final class EchoProbe: Sendable {
  struct Notice: Sendable, Equatable {
    let runId: Int64
    let chatId: Int64
    let text: String
  }

  private let notices = Mutex<[Notice]>([])
  private let pokes = Mutex<Int>(0)

  var recorded: [Notice] { notices.withLock { $0 } }
  var pokeCount: Int { pokes.withLock { $0 } }

  func record(_ notice: Notice) {
    notices.withLock { $0.append(notice) }
  }

  func poke() {
    pokes.withLock { $0 += 1 }
  }
}

/// An outbox that records every notice, or refuses them all — so the best-effort contract is
/// observable: a store that cannot take the line must not stop the command it announces.
private struct ProbeOutbox: OutboxStore {
  let probe: EchoProbe
  var failing = false

  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool { true }

  func enqueueNotice(runId: Int64, chatId: Int64, text: String) throws(StoreError) -> Bool {
    guard failing == false else {
      throw StoreError.diskFull
    }
    probe.record(EchoProbe.Notice(runId: runId, chatId: chatId, text: text))
    return true
  }

  func markSent(
    runId: Int64,
    stepIndex: Int,
    telegramMessageId: Int64,
    now: Date
  ) throws(StoreError) {}

  func pendingOutbound() throws(StoreError) -> [OutboxRow] { [] }
}

@Suite struct OutboxInvocationEchoTests {
  private func invocation(
    detail: String,
    tool: String = "bash",
    runId: Int64 = 11,
    chatId: Int64 = 42
  ) -> ToolInvocationEcho {
    ToolInvocationEcho(runId: runId, chatId: chatId, tool: tool, detail: detail)
  }

  @Test func theEchoNamesTheToolTheInterruptAndTheCommand() {
    // given / when
    let text = OutboxInvocationEcho.text(
      for: invocation(detail: "swift build"),
      redactor: SecretRedactor(secretValues: [])
    )

    // then — gateway-authored framing, the command verbatim inside it
    #expect(text.contains("bash"))
    #expect(text.contains("/stop"))
    #expect(text.contains("swift build"))
  }

  @Test func theEchoRedactsAnExactSecret() {
    // given — a command carrying a live secret value
    let redactor = SecretRedactor(secretValues: ["sk-live-9999"])

    // when
    let text = OutboxInvocationEcho.text(
      for: invocation(detail: "curl -H 'Auth: sk-live-9999' https://example.com"),
      redactor: redactor
    )

    // then
    #expect(text.contains("sk-live-9999") == false)
    #expect(text.contains("curl"))
  }

  @Test func theEchoIsLengthBounded() {
    // given — a command far longer than the owner-facing preview cap
    let command = String(repeating: "x", count: ToolOutputCap.approvalPreviewGraphemes * 3)

    // when
    let text = OutboxInvocationEcho.text(
      for: invocation(detail: command),
      redactor: SecretRedactor(secretValues: [])
    )

    // then — cut with the canonical marker, and the whole line stays near the cap
    #expect(text.contains(ToolOutputCap.truncationMarker))
    #expect(text.count < ToolOutputCap.approvalPreviewGraphemes + 100)
  }

  @Test func oneChunkIsEnqueuedAndTheDispatcherIsPoked() async {
    // given
    let probe = EchoProbe()
    let echo = OutboxInvocationEcho(
      outbox: ProbeOutbox(probe: probe),
      redactor: SecretRedactor(secretValues: []),
      notifyOutbox: { probe.poke() },
      logger: Logger(label: "test")
    )

    // when
    await echo.echo(invocation(detail: "ls -la", runId: 31, chatId: 64))

    // then — one line, addressed to the run's own delivery sequence, and drained straight away
    #expect(probe.recorded.count == 1)
    #expect(probe.recorded.first?.runId == 31)
    #expect(probe.recorded.first?.chatId == 64)
    #expect(probe.recorded.first?.text.contains("ls -la") == true)
    #expect(probe.pokeCount == 1)
  }

  @Test func aStoreFailureNeitherThrowsNorPokes() async {
    // given — an outbox that refuses the line
    let probe = EchoProbe()
    let echo = OutboxInvocationEcho(
      outbox: ProbeOutbox(probe: probe, failing: true),
      redactor: SecretRedactor(secretValues: []),
      notifyOutbox: { probe.poke() },
      logger: Logger(label: "test")
    )

    // when — best-effort by contract: the caller runs the command regardless
    await echo.echo(invocation(detail: "ls -la"))

    // then
    #expect(probe.recorded.isEmpty)
    #expect(probe.pokeCount == 0)
  }
}
