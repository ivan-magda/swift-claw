import ClawCore
import ClawData
import ClawGateway
import ClawTestSupport
import ClawWorkspace
import Foundation
import Testing

@testable import clawd

/// The composition root is the only production writer of three of the five frozen compatibility
/// fields, and the only place the learning flag decides whether the loop exists at all. The
/// `TurnRunner` hop is tested against a double, so without this suite the real closure never runs.
@Suite struct LearningCompositionTests {
  @Test func theArmedRootFreezesTheSurfaceABoundRunRanOn() throws {
    // given — a real builder over real stores, learning armed, and one bound run from its own fire
    let builder = try LearningComposition.makeBuilder(learningEnabled: true)
    let runId = try LearningComposition.fireBoundRun(builder)
    let freeze = builder.makeLearningSurfaceFreeze(
      toolDefinitions: LearningComposition.toolDefinitions,
      workspace: LearningComposition.workspace()
    )

    // when
    freeze(runId, "pv-at-pickup")

    // then — all five fields, from the values in force at pickup
    let frozen = try #require(try builder.stores.learning.compatibility(runId: runId))
    #expect(frozen.policyVersion == "pv-at-pickup")
    #expect(frozen.contextSchemaVersion == RunSurface.currentContextSchemaVersion)
    #expect(
      frozen.toolCatalogDigest
        == DaemonBuilder.toolCatalogDigest(LearningComposition.toolDefinitions)
    )
    #expect(frozen.skillSetDigest == DaemonBuilder.skillSetDigest([]))
    #expect(frozen.configuredRoute == CompositionAcceptance.qualifiedModel)
    #expect(builder.makeLearningService() != nil)
  }

  @Test func theDisarmedRootComposesNoServiceAndFreezesNothing() throws {
    // given — the same root with `CLAW_LEARNING_ENABLED` unset
    let builder = try LearningComposition.makeBuilder(learningEnabled: false)
    let runId = try LearningComposition.fireBoundRun(builder)
    let freeze = builder.makeLearningSurfaceFreeze(
      toolDefinitions: LearningComposition.toolDefinitions,
      workspace: LearningComposition.workspace()
    )

    // when
    freeze(runId, "pv-at-pickup")

    // then — the daemon behaves exactly as it does today: nothing to sweep, nothing frozen
    #expect(builder.makeLearningService() == nil)
    #expect(try builder.stores.learning.compatibility(runId: runId) == nil)
  }

  @Test func theToolCatalogDigestCoversRiskAndIgnoresCatalogOrder() {
    // given — the same two tools at different risk tiers, and the same pair reordered
    let safe = LearningComposition.tool(name: "file_read", risk: .safe)
    let ask = LearningComposition.tool(name: "file_write", risk: .ask)
    let downgraded = LearningComposition.tool(name: "file_write", risk: .safe)

    // when
    let digest = DaemonBuilder.toolCatalogDigest([safe, ask])

    // then — a risk downgrade is a different surface; declaration order is not
    #expect(DaemonBuilder.toolCatalogDigest([ask, safe]) == digest)
    #expect(DaemonBuilder.toolCatalogDigest([safe, downgraded]) != digest)
    #expect(DaemonBuilder.toolCatalogDigest([safe]) != digest)
  }

  @Test func theSkillSetDigestCoversDescriptionsAndIgnoresScanOrder() {
    // given — the index rows the context injects, which is name plus description
    let plan = LearningComposition.skill(name: "plan", description: "Draft a plan")
    let ship = LearningComposition.skill(name: "ship", description: "Cut a release")
    let reworded = LearningComposition.skill(name: "ship", description: "Publish a release")

    // when
    let digest = DaemonBuilder.skillSetDigest([plan, ship])

    // then
    #expect(DaemonBuilder.skillSetDigest([ship, plan]) == digest)
    #expect(DaemonBuilder.skillSetDigest([plan, reworded]) != digest)
    #expect(DaemonBuilder.skillSetDigest([]) != digest)
  }
}

// MARK: - Fixtures

private enum LearningComposition {
  static let toolDefinitions = [
    tool(name: "file_read", risk: .safe),
    tool(name: "web_fetch", risk: .ask),
  ]

  static func makeBuilder(learningEnabled: Bool) throws -> DaemonBuilder {
    var environment = [
      AppConfig.EnvKey.stateRoot: NSTemporaryDirectory() + "clawd-learn-" + UUID().uuidString,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ]
    if learningEnabled {
      environment[AppConfig.EnvKey.learningEnabled] = "true"
    }
    return try CompositionAcceptance.makeBuilder(
      http: ScriptedHTTPExecutor([]),
      config: try AppConfig.load(environment: environment)
    )
  }

  /// A scheduled job fired through the production path, so the run carries the real binding the
  /// freeze joins against — and carries none at all when the flag is off.
  static func fireBoundRun(_ builder: DaemonBuilder) throws -> Int64 {
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let job = try builder.stores.scheduledJobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    guard case .fired(let fired) = try builder.stores.scheduledJobs.fireNow(jobId: job.id, now: now)
    else {
      throw StoreError.unexpected("job \(job.id) refused to fire")
    }
    return fired.runId
  }

  static func workspace() -> FileSystemWorkspace {
    FileSystemWorkspace(root: URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString))
  }

  static func tool(name: String, risk: RiskLevel) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: name,
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: risk
    )
  }

  static func skill(name: String, description: String) -> SkillDescriptor {
    SkillDescriptor(
      name: name,
      description: description,
      directory: URL(fileURLWithPath: "/tmp/skills/" + name)
    )
  }
}
