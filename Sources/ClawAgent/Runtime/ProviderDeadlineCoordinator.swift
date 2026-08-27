import ClawCore
import Foundation
import Synchronization

// MARK: - Outcome

/// What a raced provider call settled on once every child has been drained. `notStarted` and
/// `mayHaveStarted` carry the disposition the runtime's accounting reads; `completed` preserves a
/// response that landed alongside a won deadline so its authoritative usage is never discarded.
public enum ProviderDeadlineAccounting: Sendable, Equatable {
  case notStarted
  case mayHaveStarted(observedCompletionTokens: Int)
  case completed(ChatResponse)
}

/// The typed result of a deadline race. Children hand back value enums instead of throwing across
/// the task group, so the group discards no loser: a raced success, a typed failure, and a
/// timed-out disposition all survive to here.
///
/// The `failed` payload boxes `any Error`; every error a provider call raises here (a `ProviderError`,
/// a `ProviderFailure`, a cancellation) is itself a Sendable value, which is what the coordinator's
/// unchecked child boxes rest on.
public enum ProviderDeadlineOutcome: @unchecked Sendable {
  case response(ChatResponse)
  case failed(any Error)
  case timedOut(ProviderDeadlineAccounting)
}

// MARK: - Lock-backed winner

/// The one participant a race settles on first.
enum ProviderRaceParticipant: Sendable {
  case provider
  case deadline
}

/// A single lock-backed winner shared by a race's children. The first `claim` wins; later claimants
/// see the decision and stand down, so the loser is drained rather than allowed to control UX. The
/// lock is never held across an `await`: `claim` and `decided` take it, mutate or read, and release
/// before returning.
final class ProviderRaceBox: Sendable {
  private let winner = Mutex<ProviderRaceParticipant?>(nil)

  /// True when `participant` is the first to claim the race.
  func claim(_ participant: ProviderRaceParticipant) -> Bool {
    winner.withLock { current in
      guard current == nil else {
        return false
      }
      current = participant
      return true
    }
  }

  var decided: ProviderRaceParticipant? {
    winner.withLock { current in
      current
    }
  }
}

// MARK: - Child results

/// A buffered `complete` call's own outcome, captured as a value so the provider child never throws
/// across the group. Boxes `any Error`; the conformers it holds (`ProviderError`, `ProviderFailure`,
/// cancellation) are all Sendable, which is the invariant behind the unchecked conformance.
public enum ProviderCallResult: @unchecked Sendable {
  case response(ChatResponse)
  case failed(any Error)
}

/// What the stream consumer saw. The authoritative terminal comes from the stream's own join; this
/// reports only whether the consumer reached it or was cut, and flags an accumulation that overran
/// its cap. The consumer's accumulated text drives live drafts and the overflow refusal — never the
/// final reply, which the terminal owns — so `completed` carries no content of its own.
enum StreamConsumerOutcome: Sendable {
  case completed
  case cut
  case overflowed
}

// MARK: - Coordinator

/// Replaces the turn runtimes' deadline races. Children return value enums and a lock picks the
/// winner, so no task group discards a loser; every provider, stream consumer, timer, typing, and
/// draft child is drained before an outcome is returned.
public enum ProviderDeadlineCoordinator {}

// MARK: - Buffered Race

extension ProviderDeadlineCoordinator {
  /// Races a buffered provider call against a wall-clock deadline. Both children return value enums,
  /// so the group discards neither; the first lock winner decides the owner-visible outcome, then the
  /// loser is drained. A response that lands under a won deadline survives as `.completed` for its
  /// authoritative usage; a provider that wins outright returns its response or its typed failure.
  public static func raceBuffered(
    deadlineSeconds: Int,
    clock: any Clock<Duration>,
    call: @escaping @Sendable () async -> ProviderCallResult
  ) async -> ProviderDeadlineOutcome {
    let box = ProviderRaceBox()
    var providerResult: ProviderCallResult?

    await withTaskGroup(of: BufferedChild.self) { group in
      group.addTask {
        .provider(await call())
      }
      group.addTask {
        try? await clock.sleep(for: .seconds(deadlineSeconds))
        return .deadline
      }

      for await child in group {
        switch child {
        case .provider(let result):
          providerResult = result
          _ = box.claim(.provider)
          group.cancelAll()
        case .deadline:
          _ = box.claim(.deadline)
          group.cancelAll()
        }
      }
    }

    // The provider child always returns, so the loser is in hand no matter who took the lock.
    guard let providerResult else {
      return .timedOut(.mayHaveStarted(observedCompletionTokens: 0))
    }
    if box.decided == .deadline {
      return Self.timedOut(fromLoser: providerResult)
    }
    switch providerResult {
    case .response(let response):
      return .response(response)
    case .failed(let error):
      return .failed(error)
    }
  }
}

// MARK: - Streaming Race

extension ProviderDeadlineCoordinator {
  /// Races the stream consumer, the draft/typing loop, and the wall-clock deadline. The consumer and
  /// the deadline contend for the lock; the loop is auxiliary. Every child is drained by the group,
  /// then the coordinator performs the one bounded join — `cancelAndAwait()` — that reads the
  /// stream's authoritative terminal. A cached `.completed` means the reply landed and succeeds even
  /// when the deadline took the lock first; otherwise the drained termination carries the timeout's
  /// disposition. The bound on that join is the transport's own primitive, not an inline wait the
  /// coordinator adds.
  static func raceStreaming(
    stream: LLMEventStream,
    deadlineSeconds: Int,
    clock: any Clock<Duration>,
    consume: @escaping @Sendable (LLMEventStream, ProviderRaceBox) async -> StreamConsumerOutcome,
    auxiliary: @escaping @Sendable (ProviderRaceBox) async -> Void
  ) async -> ProviderDeadlineOutcome {
    let box = ProviderRaceBox()
    var consumerOutcome: StreamConsumerOutcome?

    await withTaskGroup(of: StreamChild.self) { group in
      group.addTask {
        .consumer(await consume(stream, box))
      }
      group.addTask {
        try? await clock.sleep(for: .seconds(deadlineSeconds))
        // Cancel only if the deadline actually won: that closes the queue so the consumer's iteration
        // ends promptly. The authoritative join happens once, below — never here.
        if box.claim(.deadline) {
          stream.cancel()
        }
        return .deadline
      }
      group.addTask {
        await auxiliary(box)
        return .auxiliary
      }

      for await child in group {
        switch child {
        case .consumer(let outcome):
          consumerOutcome = outcome
          _ = box.claim(.provider)
          group.cancelAll()
        case .deadline:
          group.cancelAll()
        case .auxiliary:
          continue
        }
      }
    }

    // The single, coordinator-owned drain. It bounds the deadline join through the stream's own
    // primitive rather than an inline wait: a completed producer returns at once, a cancelled one as
    // soon as it acknowledges — the same guarantee the transport gives `cancelAndAwait`.
    let termination = await stream.cancelAndAwait()
    return Self.streamingOutcome(consumer: consumerOutcome, termination: termination)
  }
}

// MARK: - Bounded Ephemeral Send

extension ProviderDeadlineCoordinator {
  /// Awaits a best-effort ephemeral send but abandons it at `timeout`, owning both children so no
  /// send outlives its turn: whichever finishes first wins, the loser is cancelled, and the group
  /// drains it before returning. The send must observe cancellation for the abandon to be prompt —
  /// production sinks do; a sink that ignores it is bounded only by `timeout` having already elapsed.
  static func sendBounded(
    timeout: Duration,
    clock: any Clock<Duration>,
    send: @escaping @Sendable () async -> Void
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await send()
      }
      group.addTask {
        try? await clock.sleep(for: timeout)
      }
      _ = await group.next()
      group.cancelAll()
    }
  }
}

// MARK: - Outcome Mapping

private extension ProviderDeadlineCoordinator {
  /// The buffered group's element. Plainly `Sendable`: `ProviderCallResult` already carries the
  /// unchecked box for its error, so the enum wrapping it needs no further escape.
  enum BufferedChild: Sendable {
    case provider(ProviderCallResult)
    case deadline
  }

  /// The streaming group's element.
  enum StreamChild: Sendable {
    case consumer(StreamConsumerOutcome)
    case deadline
    case auxiliary
  }

  /// The timed-out disposition a drained provider loser carries. A response that landed keeps its
  /// authoritative usage. A provider that proved no start (a `notStarted` failure) owes nothing, and
  /// so does a bare `CancellationError` — the contract's proof the attempt never reached transport. A
  /// typed inference cancellation keeps its observed lower bound. Every remaining shape defers to
  /// `ProviderFailureAccounting.classify`, the one reducer every surface reads, so a bare provider
  /// error or an untyped failure resolves to the same disposition at both entry points rather than
  /// being booked conservatively here alone.
  static func timedOut(fromLoser result: ProviderCallResult) -> ProviderDeadlineOutcome {
    switch result {
    case .response(let response):
      return .timedOut(.completed(response))
    case .failed(let error):
      if let cancellation = error as? ProviderInferenceCancellation {
        return .timedOut(
          .mayHaveStarted(observedCompletionTokens: cancellation.observedCompletionTokens)
        )
      }
      if error is CancellationError {
        return .timedOut(.notStarted)
      }
      switch ProviderFailureAccounting.classify(error) {
      case .notStarted:
        return .timedOut(.notStarted)
      case .mayHaveStarted(let observed):
        return .timedOut(.mayHaveStarted(observedCompletionTokens: observed))
      }
    }
  }

  /// Interprets the joined terminal against what the consumer saw. Overflow is decided first — it is
  /// a local refusal, not a provider outcome. A completed terminal succeeds and is authoritative: its
  /// content is the final reply, never the consumer's delta accumulation, which drove only live
  /// drafts and can lag a done item that supersedes the deltas (so persisted text and replay state
  /// stay in agreement). A failure keeps its typed cause; a cancellation carries its accounting.
  static func streamingOutcome(
    consumer: StreamConsumerOutcome?,
    termination: LLMStreamTermination
  ) -> ProviderDeadlineOutcome {
    if case .overflowed = consumer {
      return .failed(AccumulatedStreamContentTooLarge())
    }
    switch termination {
    case .completed(let terminal):
      return .response(terminal)
    case .failed(let failure):
      return .failed(failure)
    case .cancelled(.notStarted):
      return .timedOut(.notStarted)
    case .cancelled(.mayHaveStarted(let observed)):
      return .timedOut(.mayHaveStarted(observedCompletionTokens: observed))
    }
  }
}
