import Foundation

// MARK: - Provider call identity

/// The local identity of one logical provider round-trip.
public struct ProviderCallID: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public protocol ProviderCallIDGenerating: Sendable {
  func next() -> ProviderCallID
}

public struct UUIDProviderCallIDGenerator: ProviderCallIDGenerating {
  public init() {}

  public func next() -> ProviderCallID {
    ProviderCallID(rawValue: UUID().uuidString.lowercased())
  }
}

// MARK: - Cost policy

public enum LLMCostPolicy: Sendable, Equatable {
  case metered
  case includedPlan
}

// MARK: - Input reservation policy

/// The token reservation a route needs on top of ordinary text estimation.
public enum LLMInputReservationPolicy: Sendable, Equatable {
  case textOnly
  case replayState(tokensPerByte: Int, framingTokensPerState: Int, aggregateByteCap: Int)

  public func additionalTokens(for messages: [ChatMessage]) -> Int {
    switch self {
    case .textOnly:
      0
    case .replayState(let tokensPerByte, let framingTokensPerState, let aggregateByteCap):
      Self.replayStateTokens(
        for: messages,
        tokensPerByte: tokensPerByte,
        framingTokensPerState: framingTokensPerState,
        aggregateByteCap: aggregateByteCap
      )
    }
  }
}

public enum LLMReplayStateBounds {
  public static let maximumStateBytes = 1024 * 1024
  public static let maximumAggregateBytes = 4 * 1024 * 1024
}

extension LLMInputReservationPolicy {
  public static let chatGPTReplayState = LLMInputReservationPolicy.replayState(
    tokensPerByte: 2,
    framingTokensPerState: 256,
    aggregateByteCap: LLMReplayStateBounds.maximumAggregateBytes
  )
}

// MARK: - Checked Reservation Arithmetic

private extension LLMInputReservationPolicy {
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

    return max(
      0,
      SaturatingArithmetic.sum(
        SaturatingArithmetic.product(selectedBytes, tokensPerByte),
        SaturatingArithmetic.product(stateCount, framingTokensPerState)
      )
    )
  }

  static func accumulate(_ running: Int, adding bytes: Int, cap: Int) -> Int {
    let (sum, overflowed) = running.addingReportingOverflow(bytes)
    return overflowed ? cap : min(sum, cap)
  }
}

// MARK: - Saturating budget arithmetic

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

/// Whether a failed attempt could have generated tokens the owner will be charged for.
public enum ProviderFailureAccounting: Sendable, Equatable {
  case notStarted
  case mayHaveStarted(observedCompletionTokens: Int)
}

extension ProviderFailureAccounting {
  public static func mayHaveStarted(observing observedCompletionTokens: Int) -> Self {
    .mayHaveStarted(observedCompletionTokens: max(0, observedCompletionTokens))
  }
}

// MARK: - Ambiguous cancellation

/// Cancellation of an attempt that had already been handed to the transport.
public struct ProviderInferenceCancellation: Error, Sendable, Equatable {
  public let observedCompletionTokens: Int

  public init(observing observedCompletionTokens: Int) {
    self.observedCompletionTokens = max(0, observedCompletionTokens)
  }
}
