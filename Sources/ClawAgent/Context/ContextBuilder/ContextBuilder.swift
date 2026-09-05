import ClawCore
import Foundation

public struct ContextBuilder: Sendable {
  public static let memoryFetchLimit = 100
  public static let recallCandidateLimit = 20
  public static let recallInjectionLimit = 5

  static let untrustedUserLabel = "untrusted_user_message"
  /// The fence label the pinned lesson row renders under. `package` so the gateway suite asserts
  /// the label this builder emits instead of repeating the literal.
  package static let lessonsLabel = "job lessons"

  let systemPrompt: String
  let proactiveSystemPrompt: String

  let workspace: any WorkspaceReading
  let memoryStore: any MemoryStore
  let retriever: any Retriever
  let budget: ContextBudget
  let fenceLabels: ToolFenceLabels

  private let policyStaticSubhash: String

  let now: @Sendable () -> Date
  let warn: @Sendable (String) -> Void

  public init(
    systemPrompt: String,
    proactiveSystemPrompt: String = SystemPrompt.proactive,
    workspace: any WorkspaceReading,
    memoryStore: any MemoryStore,
    retriever: any Retriever,
    budget: ContextBudget,
    fenceLabels: ToolFenceLabels = .undeclared,
    policyStaticSubhash: String = "",
    now: @escaping @Sendable () -> Date = Date.init,
    warn: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.systemPrompt = systemPrompt
    self.proactiveSystemPrompt = proactiveSystemPrompt

    self.workspace = workspace
    self.memoryStore = memoryStore
    self.retriever = retriever
    self.budget = budget
    self.fenceLabels = fenceLabels

    self.policyStaticSubhash = policyStaticSubhash

    self.now = now
    self.warn = warn
  }

  /// - Parameter lessons: the set the run's binding froze, or nil for a run with no binding. A
  ///   non-empty set is assembled whole ahead of every truncatable row and taints the memory
  ///   selection, so a bound run can never be answered against a shortened or substituted set.
  public func assemble(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    origin: RunOrigin,
    lessons: LessonSet? = nil
  ) throws -> BuildResult {
    var ownerNotices: [String] = []

    // An empty set is not a row: it says only that the job has learned nothing yet, so rendering
    // it would spend budget and raise taint for no content.
    let pinned = lessons.flatMap { set in
      set.isEmpty ? nil : set
    }
    let fixedSections = buildFixedSections(
      origin: origin,
      lessons: pinned,
      ownerNotices: &ownerNotices
    )
    let residual = BudgetFitter.residual(for: fixedSections, budget: budget)
    let truncatableSections = buildTruncatableSections(
      snapshot: snapshot,
      sessionId: sessionId,
      origin: origin,
      residual: residual,
      excludeSensitiveMemory: snapshot.isTainted || pinned != nil,
      ownerNotices: &ownerNotices
    )

    let fitted = try BudgetFitter.fitWithUnits(
      fixedSections + truncatableSections,
      budget: budget
    )
    if let notice = droppedSkillsNotice(fitted: fitted, requested: truncatableSections) {
      ownerNotices.append(notice)
    }
    let messages = renderMessages(fitted: fitted, snapshot: snapshot)

    return BuildResult(
      messages: messages,
      ownerNotices: ownerNotices,
      hasPrivateDataAccess: hasPrivateDataAccess(fitted),
      hasPinnedLessons: pinned != nil,
      policyVersion: currentPolicyVersion()
    )
  }
}

// MARK: - Policy Fingerprint

public extension ContextBuilder {
  /// The system-tier prompt materials in the pinned order (ARCHITECTURE.md §11), RAW (pre "## path"
  /// wrapping), folded into the injected static sub-hash. Reused verbatim at pick-up (the
  /// persisted `policy_version`, stamped by `TurnRunner`) and recomputed at callback resolution so
  /// the two can never diverge. BOTH prompt variants fold in — the recompute seams are zero-argument
  /// closures with no run (hence no origin) in scope, so the fingerprint must be origin-independent;
  /// an edit to either variant conservatively invalidates parked approvals. `public` because
  /// `TurnRunner` (ClawGateway) stamps with it cross-module and `assemble` returns it — a `private`
  /// helper would be invisible to both the stamp seam and `@testable`.
  func currentPolicyVersion() -> String {
    PolicyFingerprint.combined(
      staticSubhash: policyStaticSubhash,
      promptMaterials: [
        systemPrompt,
        proactiveSystemPrompt,
        rawPromptText(.soul),
        rawPromptText(.agents),
        rawPromptText(.tools),
      ]
    )
  }
}

// MARK: - Policy Materials

private extension ContextBuilder {
  /// The uncapped raw file text for a system-tier prompt file; missing/unreadable folds in as "".
  /// Uncapped because these files load uncapped in `buildFixedSections`.
  func rawPromptText(_ file: WorkspaceFile) -> String {
    let loadedFile = workspace.load(file: file, maxGraphemes: nil)
    switch loadedFile.outcome {
    case .present:
      return loadedFile.text
    case .overCap, .missing, .unreadable:
      return ""
    }
  }
}

// MARK: - Private Data Access

private extension ContextBuilder {
  func hasPrivateDataAccess(_ fitted: [FittedSection]) -> Bool {
    fitted.contains { section in
      section.id == .userFile || section.id == .memoryFile || section.id == .memoryItems
    }
  }
}
