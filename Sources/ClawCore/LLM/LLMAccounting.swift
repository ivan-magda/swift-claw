import Foundation

// MARK: - Provider call identity

/// The local identity of one logical provider round-trip — stable across clean wire retries and the
/// stream-to-buffered fallback, fresh for each tool-loop round. Usage rows are idempotent on it, so
/// a terminal commit that races an earlier one changes no total.
///
/// The raw value is a string rather than a UUID so migrated rows (`legacy:<rowid>`) and live
/// identifiers share one domain instead of forcing the schema to carry two shapes.
public struct ProviderCallID: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Mints call identities. Callers take this rather than reaching for a generator directly, so a test
/// can pin the identities a run records instead of matching against randomness.
public protocol ProviderCallIDGenerating: Sendable {
  func next() -> ProviderCallID
}

/// The live generator. A random UUID needs no coordination with the database to stay unique, which
/// matters because the ID is minted before the transaction that would discover a collision.
public struct UUIDProviderCallIDGenerator: ProviderCallIDGenerating {
  public init() {}

  public func next() -> ProviderCallID {
    ProviderCallID(rawValue: UUID().uuidString.lowercased())
  }
}

// MARK: - Cost policy

/// How a route is billed. Composition injects it; no call site infers billing from a model name.
public enum LLMCostPolicy: Sendable, Equatable {
  case metered
  /// A subscription route. Cost is a confirmed zero recorded under its own source, which is what
  /// keeps the never-a-silent-$0 rule satisfied rather than bypassed.
  case includedPlan
}

// MARK: - Input reservation policy

/// The token reservation a route needs on top of ordinary text estimation. Composition injects it,
/// so replay state participates in every token gate without the gates learning what state is.
public enum LLMInputReservationPolicy: Sendable, Equatable {
  case textOnly
  case replayState(tokensPerByte: Int, framingTokensPerState: Int, aggregateByteCap: Int)

  /// Reserves for replay state from payload *size* alone. Reading the payload is not an option: the
  /// adapter that produced it is the only code allowed to interpret it, so the reservation
  /// deliberately overshoots what re-encoding those bytes into request JSON will cost. Erring high
  /// can only over-reserve; erring low would let replay state slip past a token gate.
  public func additionalTokens(for messages: [ChatMessage]) -> Int {
    switch self {
    case .textOnly:
      return 0
    case .replayState(let tokensPerByte, let framingTokensPerState, let aggregateByteCap):
      return Self.replayStateTokens(
        for: messages,
        tokensPerByte: tokensPerByte,
        framingTokensPerState: framingTokensPerState,
        aggregateByteCap: aggregateByteCap
      )
    }
  }
}

/// What replay state may weigh: one state, and one request's worth of them.
///
/// They live beside the reservation policy rather than inside the adapter because the token gate
/// reserves against the same aggregate the adapter selects under. Stated twice they would drift, and
/// a gate reserving for a budget nobody selects by is a gate that no longer describes what is sent.
public enum LLMReplayStateBounds {
  public static let maximumStateBytes = 1024 * 1024
  public static let maximumAggregateBytes = 4 * 1024 * 1024
}

extension LLMInputReservationPolicy {
  /// The managed ChatGPT route's reservation, matching the aggregate byte budget the adapter selects
  /// replay state under. Two tokens per byte plus per-state framing is the overshoot that covers
  /// re-encoding those bytes without decoding them.
  public static let chatGPTReplayState = LLMInputReservationPolicy.replayState(
    tokensPerByte: 2,
    framingTokensPerState: 256,
    aggregateByteCap: LLMReplayStateBounds.maximumAggregateBytes
  )
}

// MARK: - Checked Reservation Arithmetic

private extension LLMInputReservationPolicy {
  /// Framing is charged per state rather than per message, because a message carrying none costs
  /// nothing to re-encode.
  static func replayStateTokens(
    for messages: [ChatMessage],
    tokensPerByte: Int,
    framingTokensPerState: Int,
    aggregateByteCap: Int
  ) -> Int {
    var selectedBytes = 0
    var stateCount = 0
    for message in messages {
      guard let state = message.providerState else {
        continue
      }
      stateCount += 1
      selectedBytes = accumulate(selectedBytes, adding: state.payload.count, cap: aggregateByteCap)
    }

    // A negative rate is a misconfiguration, and letting its product through would subtract from the
    // caller's gate — the one direction a reservation must never move.
    return max(
      0,
      SaturatingArithmetic.sum(
        SaturatingArithmetic.product(selectedBytes, tokensPerByte),
        SaturatingArithmetic.product(stateCount, framingTokensPerState)
      )
    )
  }

  /// Bytes are capped before they are multiplied, so the reservation tracks what the adapter would
  /// actually select rather than the whole history. An accumulation that overflows has certainly
  /// passed the cap, which makes clamping it exact rather than merely safe.
  static func accumulate(_ running: Int, adding bytes: Int, cap: Int) -> Int {
    let (sum, overflowed) = running.addingReportingOverflow(bytes)
    return overflowed ? cap : min(sum, cap)
  }
}

// MARK: - Saturating budget arithmetic

/// Clamping rather than trapping. Every caller is totalling a budget — tokens to reserve, bytes to
/// hold — so a sum this large has already passed the limit it feeds: clamping refuses the work,
/// which is the safe direction, instead of taking the daemon down mid-turn.
public enum SaturatingArithmetic {
  public static func sum(_ lhs: Int, _ rhs: Int) -> Int {
    let (total, overflowed) = lhs.addingReportingOverflow(rhs)
    return overflowed ? .max : total
  }

  public static func product(_ lhs: Int, _ rhs: Int) -> Int {
    let (total, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
    return overflowed ? .max : total
  }
}

// MARK: - Failure accounting

/// Whether a failed attempt could have generated tokens the owner will be charged for. It is the
/// vendor-neutral answer the runtime branches on, so no call site has to know whether the attempt
/// went out through `complete` or `stream`.
public enum ProviderFailureAccounting: Sendable, Equatable {
  case notStarted
  case mayHaveStarted(observedCompletionTokens: Int)
}

extension ProviderFailureAccounting {
  /// Builds `mayHaveStarted` from a count production code observed. Observed counts are lower bounds
  /// read off already-bounded visible text and tool arguments, so a negative is a bug in the
  /// counting rather than a signal: flooring it keeps a miscount from crediting a failed attempt
  /// with negative usage, which would silently refund tokens the provider may well have generated.
  public static func mayHaveStarted(observing observedCompletionTokens: Int) -> Self {
    .mayHaveStarted(observedCompletionTokens: max(0, observedCompletionTokens))
  }
}

// MARK: - Ambiguous cancellation

/// Cancellation of an attempt that had already been handed to the transport. A plain
/// `CancellationError` says the caller changed its mind; this says the model may have been asked
/// anyway, so the tokens it may have generated still have to be accounted for.
///
/// A returned session reports this through its terminal, so only `complete` — which has no session
/// to report through — throws it.
public struct ProviderInferenceCancellation: Error, Sendable, Equatable {
  public let observedCompletionTokens: Int

  /// Floors the count for the same reason `mayHaveStarted(observing:)` does: a miscount must never
  /// credit a cancelled attempt with negative usage.
  public init(observing observedCompletionTokens: Int) {
    self.observedCompletionTokens = max(0, observedCompletionTokens)
  }
}
