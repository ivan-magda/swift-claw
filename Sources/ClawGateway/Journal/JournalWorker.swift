import ClawCore
import Foundation
import Logging
import ServiceLifecycle

public actor JournalWorker: Service {
  public static let sweepInterval: Duration = .seconds(JournalLimits.sweepIntervalSeconds)
  private let ownerUserID: Int64
  private let store: any JournalStore
  private let files: any JournalFiles
  private let mutationGate: WorkspaceMutationGate
  private let codec: JournalSummaryCodec
  private let summarizer: JournalSummarizer
  private let roster: ProviderRoster
  private let cooldown: (any PrimaryRouteCooldownTracking)?
  private let budget: RunBudget
  private let clock: any Clock<Duration>
  private let now: @Sendable () -> Date
  private let logger: Logger
  private let callIDs: any ProviderCallIDGenerating
  nonisolated private let notifications: AsyncStream<Void>
  nonisolated private let notification: AsyncStream<Void>.Continuation
  private var pendingSweep: Date?
  private var stopping = false
  private var running = false
  // Actor isolation does not serialize inference across suspension; this task owns the drain.
  private var drain: Task<Void, Never>?

  package init(
    ownerUserID: Int64,
    store: any JournalStore,
    files: any JournalFiles,
    mutationGate: WorkspaceMutationGate,
    codec: JournalSummaryCodec,
    summarizer: JournalSummarizer,
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    budget: RunBudget,
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = {
      Date()
    },
    callIDs: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger
  ) {
    self.ownerUserID = ownerUserID
    self.store = store
    self.files = files
    self.mutationGate = mutationGate
    self.codec = codec
    self.summarizer = summarizer
    self.roster = roster
    self.cooldown = cooldown
    self.budget = budget
    self.clock = clock
    self.now = now
    self.logger = logger
    self.callIDs = callIDs
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    notifications = signal.stream
    notification = signal.continuation
  }

  /// Producer hints coalesce without launching work before the service starts.
  nonisolated public func notifyPending() {
    notification.yield(())
  }

  func sweep(now: Date) async {
    guard let task = enqueueSweep(now: now) else {
      return
    }
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func shutdown() async {
    stopping = true
    notification.finish()
    drain?.cancel()
    await drain?.value
  }

  public func run() async throws {
    guard !running, !stopping else {
      return
    }
    running = true
    await cancelWhenGracefulShutdown {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in self.notifications {
            guard !Task.isCancelled else {
              break
            }
            _ = await self.enqueueSweep(now: self.now())
          }
        }
        group.addTask {
          while !Task.isCancelled {
            _ = await self.enqueueSweep(now: self.now())
            do {
              try await self.clock.sleep(for: Self.sweepInterval)
            } catch {
              break
            }
          }
        }
        await group.next()
        group.cancelAll()
      }
    }
    await shutdown()
  }
}

// MARK: - Owned Drain

private extension JournalWorker {
  func enqueueSweep(now: Date) -> Task<Void, Never>? {
    guard !stopping else {
      return nil
    }
    pendingSweep = now
    if let drain {
      return drain
    }
    let task = Task {
      await self.drainPending()
    }
    drain = task
    return task
  }

  func drainPending() async {
    defer {
      drain = nil
    }
    while !stopping, !Task.isCancelled, let sweepTime = pendingSweep {
      pendingSweep = nil
      do {
        try await drainCandidates(now: sweepTime)
      } catch {
        // Store errors can include SQL arguments. Only a fixed reason crosses logging.
        logger.error("Journal queue drain deferred after a store failure")
        return
      }
    }
  }

  func drainCandidates(now: Date) async throws {
    var candidates = try store.pendingSources(ownerUserID: ownerUserID, now: now)
    while !stopping, !Task.isCancelled, let first = candidates.first {
      let daySources = candidates.filter {
        $0.day == first.day
      }
      let binding = roster.startingRoute(
        primaryIsCooling: await cooldown?.isCooling() == true
      ).binding
      guard !stopping, !Task.isCancelled else {
        return
      }
      let prepared: JournalPreparedSummary
      do {
        prepared = try codec.prepare(sources: daySources, binding: binding, budget: budget)
      } catch JournalSummaryPreparationError.unrepresentableSource(let id) {
        try store.skipSources(ids: [id], reason: "Journal source cannot fit request", now: now)
        candidates.removeAll {
          $0.id == id
        }
        continue
      }
      let callID = callIDs.next()
      let source = prepared.sources[0]
      let savedUsage = prepared.accountant.conservativeRow(
        callID: callID,
        context: prepared.request.messages,
        observedCompletionTokens: 0,
        runID: nil,
        sessionID: source.sessionID
      )
      let request = JournalStartRequest(
        sourceIDs: prepared.sources.map(\.id),
        scope: source.scope,
        day: source.day,
        sessionID: source.sessionID,
        providerCallID: callID,
        estimate: prepared.estimate,
        conservativeUsage: savedUsage,
        budget: budget,
        costPolicy: binding.costPolicy
      )
      let batch: JournalBatch
      switch try store.startBatch(request, now: self.now()) {
      case .deferred:
        pendingSweep = nil
        return
      case .obsolete:
        let selected = Set(request.sourceIDs)
        candidates.removeAll {
          selected.contains($0.id)
        }
        continue
      case .started(let started):
        batch = started
      }
      let result = await summarizer.summarize(prepared, binding: binding, callID: callID)
      try await publish(result, prepared: prepared, batch: batch)
      let selected = Set(batch.sourceIDs)
      candidates.removeAll {
        selected.contains($0.id)
      }
    }
  }
}

// MARK: - Serialized Publication

private extension JournalWorker {
  func publish(
    _ result: JournalSummaryResult,
    prepared: JournalPreparedSummary,
    batch: JournalBatch
  ) async throws {
    let store = store
    let files = files
    let codec = codec
    let finishedAt = now()
    try await mutationGate.perform {
      var outcome: JournalOutcome
      switch result.outcome {
      case .notes:
        outcome = .written
      case .empty:
        outcome = .empty
      case .invalidSummary:
        outcome = .invalidSummary(redactedReason: "Invalid journal summary")
      case .failed:
        outcome = .failed(redactedReason: result.redactedReason ?? "Journal summary failed")
      }
      if try store.canPublish(batchID: batch.id), result.outcome == .notes {
        do {
          let text = codec.render(notes: result.notes, sources: prepared.sources)
          if !text.isEmpty {
            try files.append(day: batch.day, text: text)
          }
        } catch {
          outcome = .failed(redactedReason: Self.fileFailureReason(error))
        }
      }
      try store.finishBatch(id: batch.id, outcome: outcome, usage: result.usage, now: finishedAt)
    }
  }

  nonisolated static func fileFailureReason(_ error: any Error) -> String {
    switch error as? JournalFileError {
    case .overCap:
      "Journal day file exceeds size limit"
    case .pathRefused:
      "Journal day file path refused"
    case .unreadable:
      "Journal day file unreadable"
    default:
      "Journal day file append failed"
    }
  }
}
