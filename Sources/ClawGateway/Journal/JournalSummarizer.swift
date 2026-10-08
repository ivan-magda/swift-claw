import ClawAgent
import ClawCore
import Foundation

public struct JournalSummaryResult: Sendable {
  public enum Outcome: Sendable, Equatable {
    case notes
    case empty
    case invalidSummary
    case failed
  }

  public let outcome: Outcome
  public let notes: [JournalNote]
  public let usage: ProviderUsage?
  public let redactedReason: String?
}

public struct JournalSummarizer: Sendable {
  private let codec: JournalSummaryCodec
  private let clock: any Clock<Duration>

  public init(codec: JournalSummaryCodec, clock: any Clock<Duration>) {
    self.codec = codec
    self.clock = clock
  }

  public func summarize(
    _ prepared: JournalPreparedSummary,
    binding: LLMRouteBinding,
    callID: ProviderCallID
  ) async -> JournalSummaryResult {
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: JournalLimits.inferenceDeadlineSeconds,
      clock: clock
    ) {
      do {
        return .response(try await binding.provider.complete(request: prepared.request))
      } catch {
        return .failed(error)
      }
    }
    switch outcome {
    case .response(let response):
      let usage = reconciled(response, prepared: prepared, callID: callID)
      do {
        guard response.toolCalls.isEmpty else {
          throw JournalSummaryValidationError.invalidOutput
        }
        let notes = try codec.decode(response: response.content, sources: prepared.sources)
        return JournalSummaryResult(
          outcome: notes.isEmpty ? .empty : .notes,
          notes: notes,
          usage: usage,
          redactedReason: nil
        )
      } catch {
        return JournalSummaryResult(
          outcome: .invalidSummary,
          notes: [],
          usage: usage,
          redactedReason: "Invalid journal summary"
        )
      }
    case .timedOut(let accounting):
      let usage: ProviderUsage? =
        switch accounting {
        case .completed(let response):
          reconciled(response, prepared: prepared, callID: callID)
        case .mayHaveStarted(let observed):
          conservative(prepared, callID: callID, observed: observed)
        case .notStarted:
          nil
        }
      return JournalSummaryResult(
        outcome: .failed,
        notes: [],
        usage: usage,
        redactedReason: "Journal summary deadline exceeded"
      )
    case .failed(let error):
      let usage: ProviderUsage? =
        switch Self.failureAccounting(error) {
        case .notStarted:
          nil
        case .mayHaveStarted(let observed):
          conservative(prepared, callID: callID, observed: observed)
        }
      return JournalSummaryResult(
        outcome: .failed,
        notes: [],
        usage: usage,
        redactedReason: "Journal summary provider failed"
      )
    }
  }
}

// MARK: - Run-less Accounting

private extension JournalSummarizer {
  static func failureAccounting(_ error: any Error) -> ProviderFailureAccounting {
    if let cancellation = error as? ProviderInferenceCancellation {
      return .mayHaveStarted(observing: cancellation.observedCompletionTokens)
    }
    if error is CancellationError {
      return .notStarted
    }
    return ProviderFailureAccounting.classify(error)
  }

  func reconciled(
    _ response: ChatResponse,
    prepared: JournalPreparedSummary,
    callID: ProviderCallID
  ) -> ProviderUsage {
    prepared.accountant.reconciledRow(
      for: response,
      callID: callID,
      context: prepared.request.messages,
      runID: nil,
      sessionID: prepared.sources[0].sessionID
    )
  }

  func conservative(
    _ prepared: JournalPreparedSummary,
    callID: ProviderCallID,
    observed: Int
  ) -> ProviderUsage {
    prepared.accountant.conservativeRow(
      callID: callID,
      context: prepared.request.messages,
      observedCompletionTokens: observed,
      runID: nil,
      sessionID: prepared.sources[0].sessionID
    )
  }
}
