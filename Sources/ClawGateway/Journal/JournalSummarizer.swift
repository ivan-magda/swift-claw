import ClawAgent
import ClawCore
import Foundation

struct JournalSummaryResult: Sendable {
  enum Outcome: Sendable, Equatable {
    case notes
    case empty
    case invalidSummary
    case failed
  }

  let outcome: Outcome
  let notes: [JournalNote]
  let usage: ProviderUsage?
  let redactedReason: String?
}

package struct JournalSummarizer: Sendable {
  private let codec: JournalSummaryCodec
  private let clock: any Clock<Duration>

  package init(codec: JournalSummaryCodec, clock: any Clock<Duration>) {
    self.codec = codec
    self.clock = clock
  }

  func summarize(
    _ prepared: JournalPreparedSummary,
    binding: LLMRouteBinding,
    callID: ProviderCallID
  ) async -> JournalSummaryResult {
    let providerOutcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: JournalLimits.inferenceDeadlineSeconds,
      clock: clock
    ) {
      do {
        return .response(try await binding.provider.complete(request: prepared.request))
      } catch {
        return .failed(error)
      }
    }

    switch providerOutcome {
    case .response(let response):
      let usage = reconciledUsage(response, prepared: prepared, callID: callID)
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
          reconciledUsage(response, prepared: prepared, callID: callID)
        case .mayHaveStarted(let observedCompletionTokens):
          conservativeUsage(
            prepared,
            callID: callID,
            observedCompletionTokens: observedCompletionTokens
          )
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
        case .mayHaveStarted(let observedCompletionTokens):
          conservativeUsage(
            prepared,
            callID: callID,
            observedCompletionTokens: observedCompletionTokens
          )
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

  func reconciledUsage(
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

  func conservativeUsage(
    _ prepared: JournalPreparedSummary,
    callID: ProviderCallID,
    observedCompletionTokens: Int
  ) -> ProviderUsage {
    prepared.accountant.conservativeRow(
      callID: callID,
      context: prepared.request.messages,
      observedCompletionTokens: observedCompletionTokens,
      runID: nil,
      sessionID: prepared.sources[0].sessionID
    )
  }
}
