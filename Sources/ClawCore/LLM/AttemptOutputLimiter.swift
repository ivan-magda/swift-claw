import Foundation
import Synchronization

/// Attempt-wide bounds for model-emitted owner-visible text and tool arguments.
///
/// The normal daemon does not install these limits. Controlled callers opt in and share one limiter
/// across every model round-trip in an attempt, which prevents a two-round tool exchange from
/// receiving the full allowance twice.
package struct AttemptOutputLimits: Sendable, Equatable, Codable {
  package let maximumUTF8Bytes: Int
  package let maximumGraphemes: Int

  package init(maximumUTF8Bytes: Int, maximumGraphemes: Int) {
    precondition(maximumUTF8Bytes > 0, "the output byte limit must be positive")
    precondition(maximumGraphemes > 0, "the output grapheme limit must be positive")
    self.maximumUTF8Bytes = maximumUTF8Bytes
    self.maximumGraphemes = maximumGraphemes
  }

  enum CodingKeys: String, CodingKey {
    case maximumUTF8Bytes = "max_utf8_bytes"
    case maximumGraphemes = "max_graphemes"
  }
}

/// The cumulative output charged to an attempt. `limitExceeded` is sticky: once a stream crosses a
/// bound, a later terminal restatement cannot make the cancelled attempt valid again.
package struct AttemptOutputCounts: Sendable, Equatable, Codable {
  package let utf8Bytes: Int
  package let graphemes: Int
  package let limitExceeded: Bool

  package init(utf8Bytes: Int, graphemes: Int, limitExceeded: Bool) {
    self.utf8Bytes = utf8Bytes
    self.graphemes = graphemes
    self.limitExceeded = limitExceeded
  }
}

/// One stable model-output field observed while a provider reconstructs a streamed response. The
/// key is provider-local identity (for example a Responses output index plus field kind); it is
/// never sent on the wire or persisted as task content.
package struct AttemptOutputField: Sendable, Equatable {
  package let key: String
  package let value: String

  package init(key: String, value: String) {
    precondition(key.isEmpty == false, "an output field key must not be empty")
    self.key = key
    self.value = value
  }
}

/// One round-trip's handle into an attempt-owned limiter. Providers may update it while parsing a
/// stream; the runtime always reconciles the terminal `ChatResponse` as the authoritative last
/// check. Equality is identity equality so adding the optional scope to `ChatRequest` preserves its
/// value comparison without pretending two independent counters are interchangeable.
package struct AttemptOutputScope: Sendable, Equatable {
  fileprivate let limiter: AttemptOutputLimiter
  fileprivate let roundID: UUID

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.limiter === rhs.limiter && lhs.roundID == rhs.roundID
  }

  /// Replaces this round's current accumulation. Providers must use stable wire identities so a
  /// field appearing late cannot shift an older field to a new array position and reclaim its
  /// high-water charge. Separate fields are counted separately, so a combining scalar at a field
  /// boundary cannot merge two independently emitted values.
  package func observe(fields: [AttemptOutputField]) throws {
    try limiter.replace(
      roundID: roundID,
      fields: fields
    )
  }

  /// Rechecks the provider's whole reply. Tool names and call IDs are routing metadata, not model
  /// output charged by the experiment contract; only the raw argument strings are included.
  package func finalize(_ response: ChatResponse) throws {
    try limiter.finalize(
      roundID: roundID,
      visibleText: [response.content],
      toolArguments: response.toolCalls.map(\.argumentsJSON)
    )
  }
}

/// Lock-backed because provider parsing and the runtime's terminal reconciliation can occur on
/// different executors. No lock is held across an `await`.
package final class AttemptOutputLimiter: @unchecked Sendable {
  private struct Counts {
    var utf8Bytes = 0
    var graphemes = 0
  }

  private struct RoundState {
    var fieldHighWater: [String: Counts] = [:]
    var terminalSnapshotHighWater = Counts()

    var counts: Counts {
      let streamed = AttemptOutputLimiter.totals(Array(fieldHighWater.values))
      return Counts(
        utf8Bytes: max(streamed.utf8Bytes, terminalSnapshotHighWater.utf8Bytes),
        graphemes: max(streamed.graphemes, terminalSnapshotHighWater.graphemes)
      )
    }
  }

  private struct State {
    var rounds: [UUID: RoundState] = [:]
    var exceeded = false
  }

  package let limits: AttemptOutputLimits
  private let state = Mutex(State())

  package init(limits: AttemptOutputLimits) {
    self.limits = limits
  }

  package func beginRound() -> AttemptOutputScope {
    let roundID = UUID()
    state.withLock { current in
      current.rounds[roundID] = RoundState()
    }
    return AttemptOutputScope(limiter: self, roundID: roundID)
  }

  package var counts: AttemptOutputCounts {
    state.withLock { current in
      let totals = Self.totals(current.rounds.values.map(\.counts))
      return AttemptOutputCounts(
        utf8Bytes: totals.utf8Bytes,
        graphemes: totals.graphemes,
        limitExceeded: current.exceeded
      )
    }
  }

  fileprivate func replace(
    roundID: UUID,
    fields: [AttemptOutputField]
  ) throws {
    let exceeded = state.withLock { current -> Bool in
      guard current.exceeded == false else {
        return true
      }
      var round = current.rounds[roundID] ?? RoundState()
      Self.merge(fields: fields, into: &round.fieldHighWater)
      current.rounds[roundID] = round
      let totals = Self.totals(current.rounds.values.map(\.counts))
      let exceedsLimits =
        totals.utf8Bytes > limits.maximumUTF8Bytes
        || totals.graphemes > limits.maximumGraphemes
      if exceedsLimits {
        current.exceeded = true
      }
      return current.exceeded
    }

    if exceeded {
      throw ProviderError.localOutputLimit
    }
  }

  fileprivate func finalize(
    roundID: UUID,
    visibleText: [String],
    toolArguments: [String]
  ) throws {
    let snapshot = Self.counts(for: visibleText + toolArguments)
    let exceeded = state.withLock { current -> Bool in
      guard current.exceeded == false else { return true }
      var round = current.rounds[roundID] ?? RoundState()
      round.terminalSnapshotHighWater = Counts(
        utf8Bytes: max(round.terminalSnapshotHighWater.utf8Bytes, snapshot.utf8Bytes),
        graphemes: max(round.terminalSnapshotHighWater.graphemes, snapshot.graphemes)
      )
      current.rounds[roundID] = round
      let totals = Self.totals(current.rounds.values.map(\.counts))
      let exceedsLimits =
        totals.utf8Bytes > limits.maximumUTF8Bytes
        || totals.graphemes > limits.maximumGraphemes
      if exceedsLimits {
        current.exceeded = true
      }
      return current.exceeded
    }
    if exceeded { throw ProviderError.localOutputLimit }
  }

  private static func merge(
    fields: [AttemptOutputField],
    into highWater: inout [String: Counts]
  ) {
    precondition(Set(fields.map(\.key)).count == fields.count, "output field keys must be unique")
    for field in fields {
      let observed = counts(for: [field.value])
      let previous = highWater[field.key] ?? Counts()
      highWater[field.key] = Counts(
        utf8Bytes: max(previous.utf8Bytes, observed.utf8Bytes),
        graphemes: max(previous.graphemes, observed.graphemes)
      )
    }
  }

  private static func counts(for fields: [String]) -> Counts {
    Counts(
      utf8Bytes: fields.reduce(0) { SaturatingArithmetic.sum($0, $1.utf8.count) },
      graphemes: fields.reduce(0) { SaturatingArithmetic.sum($0, $1.count) }
    )
  }

  private static func totals(_ rounds: [Counts]) -> Counts {
    rounds.reduce(into: Counts()) { result, round in
      result.utf8Bytes = SaturatingArithmetic.sum(result.utf8Bytes, round.utf8Bytes)
      result.graphemes = SaturatingArithmetic.sum(result.graphemes, round.graphemes)
    }
  }
}
