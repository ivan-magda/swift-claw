import ClawCore

/// The trust facts the tool gate reads: the session's persisted flags at entry, the assembly's
/// private-data flag, and what this run has ingested since. The run's own flags only ever switch
/// on, so no later observation clears what an earlier one raised.
struct TurnTrust {
  /// Whether provider metadata or an executed observation ingested untrusted content.
  private(set) var ingestedUntrusted: Bool
  private var runPrivateData = false

  private let sessionTainted: Bool
  private let sessionHasPrivateData: Bool
  private let assemblyPrivateData: Bool

  /// Untrusted tool metadata and a pinned lesson set both reach the model before the first
  /// dispatch, so either arms the run's untrusted-ingestion flag from the start.
  init(
    sessionTainted: Bool,
    sessionHasPrivateData: Bool,
    assemblyPrivateData: Bool,
    hasPinnedLessons: Bool,
    toolDefinitions: [ToolDefinition]
  ) {
    let untrustedToolMetadata = toolDefinitions.contains { definition in
      definition.metadataProvenance == .untrusted
    }
    ingestedUntrusted = untrustedToolMetadata || hasPinnedLessons

    self.sessionTainted = sessionTainted
    self.sessionHasPrivateData = sessionHasPrivateData
    self.assemblyPrivateData = assemblyPrivateData
  }

  /// Whether assembly or any executed observation accessed private data.
  var hadPrivateData: Bool {
    assemblyPrivateData || runPrivateData
  }

  /// The policy inputs the gate reads for one call, reflecting every call executed before it.
  func dispatchContext(
    for call: ToolCall,
    scope: TurnScope,
    approvalAlreadyPending: Bool
  ) -> ToolDispatchContext {
    ToolDispatchContext(
      sessionTainted: sessionTainted,
      runIngestedUntrusted: ingestedUntrusted,
      assemblyPrivateData: assemblyPrivateData,
      runPrivateData: runPrivateData,
      sessionHasPrivateData: sessionHasPrivateData,
      approvalAlreadyPending: approvalAlreadyPending,
      mode: scope.mode,
      executionContext: scope.executionContext(toolCallID: call.id)
    )
  }

  /// Folds one executed observation into the run's flags.
  mutating func absorb(_ observation: ToolObservation) {
    if observation.ingestedUntrusted {
      ingestedUntrusted = true
    }
    if observation.readPrivateData {
      runPrivateData = true
    }
  }
}
