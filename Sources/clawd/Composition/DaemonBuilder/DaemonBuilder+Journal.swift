import ClawCore
import ClawGateway
import ClawWorkspace
import Foundation

extension DaemonBuilder {
  struct JournalComposition: Sendable {
    let policy: JournalPolicy
    let store: any JournalStore
    let files: any JournalFiles
    let mutationGate: WorkspaceMutationGate
    let capture: JournalSourceCapture?
    let worker: JournalWorker?
  }

  func makeJournalComposition(
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    costResolver: CostResolver,
    workspaceRoot: URL
  ) -> JournalComposition {
    let policy = config.journalPolicy
    let files = FileSystemJournalFiles(root: workspaceRoot)
    let mutationGate = WorkspaceMutationGate()
    let redactor = SecretRedactor(secretValues: redactionValues)

    let capture: JournalSourceCapture? =
      if policy.enabled {
        JournalSourceCapture(policy: policy, redact: redactor.redact)
      } else {
        nil
      }

    let worker: JournalWorker?
    if let scope = policy.scope {
      let codec = JournalSummaryCodec(costResolver: costResolver, redact: redactor.redact)
      let summarizer = JournalSummarizer(codec: codec, clock: ContinuousClock())
      worker = JournalWorker(
        ownerUserID: scope.ownerUserID,
        store: stores.journal,
        files: files,
        mutationGate: mutationGate,
        codec: codec,
        summarizer: summarizer,
        roster: roster,
        cooldown: cooldown,
        budget: config.budget,
        now: now,
        logger: logger
      )
    } else {
      worker = nil
    }

    return JournalComposition(
      policy: policy,
      store: stores.journal,
      files: files,
      mutationGate: mutationGate,
      capture: capture,
      worker: worker
    )
  }

  func reconcileJournalAtBoot() {
    do {
      try stores.journal.reconcileAtBoot(now: now())
    } catch {
      logger.error("Journal boot accounting failed")
    }
  }
}
