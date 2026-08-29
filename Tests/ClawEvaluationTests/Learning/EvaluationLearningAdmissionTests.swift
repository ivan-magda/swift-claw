import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningAdmissionTests {
  @Test func verifierAcceptsCanonicalBoundArtifactsAndSelectsTheRouteForEachOperationKind()
    async throws
  {
    // given
    let kinds: [EvaluationLearningOperationKind] = [.task, .evaluator, .reflector]

    // when
    for kind in kinds {
      let fixture = try makeEvaluationLearningAdmissionFixture(operationKind: kind)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let context = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: kind
      )

      // then — choosing the evaluator route for every kind would leave all three calls admitted.
      let expectedRoute: EvaluationLearningRouteBinding
      switch kind {
      case .task:
        expectedRoute = fixture.taskRoute
      case .evaluator:
        expectedRoute = fixture.evaluatorRoute
      case .reflector:
        expectedRoute = fixture.reflectorRoute
      }
      #expect(context.route == expectedRoute)
      #expect(context.route.retryBudget == expectedRoute.retryBudget)
    }
  }

  @Test func verifierRejectsNoncanonicalManifestBeforeAdmittingAnOperation() async throws {
    // given
    var fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifestObject = try JSONSerialization.jsonObject(
      with: Data(contentsOf: fixture.manifestURL)
    )
    let noncanonical = try JSONSerialization.data(
      withJSONObject: manifestObject,
      options: [.prettyPrinted]
    )
    try noncanonical.write(to: fixture.manifestURL)
    fixture = try fixture.rebindingManifestAndOwnerApproval()

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — accepting ordinary JSON rather than the frozen bytes admits a representation change.
    #expect(error != nil)
  }

  @Test func verifierRejectsAChangedBoundArtifact() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("changed approval".utf8).write(to: fixture.ownerApprovalURL)

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — skipping the owner-approval rehash admits a post-approval budget replacement.
    #expect(error != nil)
  }

  @Test func verifierRejectsAnOperationCoreDigestThatDiffersFromTheStartedEvent() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: String(repeating: "9", count: 64),
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — omitting the invocation-core comparison permits a switched command invocation.
    #expect(error != nil)
  }

  @Test func verifierRejectsAChangedExecutable() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("changed executable".utf8).write(to: fixture.executableURL)

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — checking only the manifest declaration leaves the executing binary unbound.
    #expect(error != nil)
  }

  @Test(arguments: [
    "provider_call_id",
    "carrier_digest",
    "route_digest",
  ])
  func verifierRejectsEachChangedProviderAdmissionField(_ changedField: String) async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture(eventMutation: changedField)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — accepting any row reaches a provider call with a mismatched pre-minted identity.
    #expect(error != nil)
  }

  @Test(arguments: [
    "task_attempts",
    "evaluator_calls",
    "reflector_calls",
    "responses_sends",
    "accounted_tokens",
  ])
  func verifierRejectsEachOwnerBudgetThatDiffersFromTheManifest(_ changedBudget: String)
    async throws
  {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture(approvalBudgetMutation: changedBudget)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — comparing only one budget dimension permits an unapproved aggregate cap.
    #expect(error != nil)
  }

  @Test func liveAdmissionDeniesWhenVerificationReturnsADifferentSuccessfulContext() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await fixture.verifier().verify(
      manifest: fixture.manifest,
      authorization: fixture.authorization,
      invocationCoreDigest: fixture.invocationCoreDigest,
      carrierSHA256: fixture.carrierSHA256,
      providerCallID: fixture.providerCallID,
      kind: .evaluator
    )
    let changed = EvaluationLearningAdmissionContext(
      jobID: initial.jobID,
      operationID: initial.operationID,
      attemptGeneration: initial.attemptGeneration,
      providerCallID: initial.providerCallID,
      manifestSHA256: initial.manifestSHA256,
      freezeCommit: initial.freezeCommit,
      executableSHA256: initial.executableSHA256,
      missingUsageTokenProxy: initial.missingUsageTokenProxy + 1,
      budgets: initial.budgets,
      route: initial.route
    )
    let admission = EvaluationLearningLiveAdmission(
      verifier: StaticEvaluationLearningAdmissionVerifier(context: changed),
      manifest: fixture.manifest,
      authorization: fixture.authorization,
      invocationCoreDigest: fixture.invocationCoreDigest,
      carrierSHA256: fixture.carrierSHA256,
      providerCallID: fixture.providerCallID,
      kind: .evaluator,
      initial: initial
    )

    // when
    let decision = await admission.evaluate()

    // then — treating successful re-verification as enough allows changed frozen limits mid-run.
    #expect(decision == .deny(cap: "evaluation-learning-integrity"))
  }
}

private struct EvaluationLearningAdmissionFixture {
  let root: URL
  let manifestURL: URL
  let ownerApprovalURL: URL
  let executableURL: URL
  let manifest: EvaluationLearningManifestBinding
  let authorization: EvaluationLearningOperationAuthorization
  let invocationCoreDigest: String
  let carrierSHA256: String
  let providerCallID: ProviderCallID
  let taskRoute: EvaluationLearningRouteBinding
  let evaluatorRoute: EvaluationLearningRouteBinding
  let reflectorRoute: EvaluationLearningRouteBinding

  func verifier() -> EvaluationLearningAdmissionVerifier {
    EvaluationLearningAdmissionVerifier(runningExecutablePath: { executableURL.path })
  }

  func rebindingManifestAndOwnerApproval() throws -> Self {
    let manifestData = try Data(contentsOf: manifestURL)
    var approval = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: ownerApprovalURL)) as? [String: Any]
    )
    approval["manifest_sha256"] = SHA256Digest.hex(manifestData)
    let approvalData = try EvaluationCanonicalJSON.data(fromJSONObject: approval)
    try approvalData.write(to: ownerApprovalURL)
    let eventURL = URL(fileURLWithPath: authorization.eventPath)
    var event = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: eventURL)) as? [String: Any]
    )
    var payload = try #require(event["payload"] as? [String: Any])
    payload["manifest_digest"] = SHA256Digest.hex(manifestData)
    event["payload"] = payload
    let eventData = try EvaluationCanonicalJSON.data(fromJSONObject: event)
    try eventData.write(to: eventURL)
    return Self(
      root: root,
      manifestURL: manifestURL,
      ownerApprovalURL: ownerApprovalURL,
      executableURL: executableURL,
      manifest: EvaluationLearningManifestBinding(
        repositoryRoot: root.path,
        evaluationRoot: root.appendingPathComponent("live-run", isDirectory: true).path,
        manifestPath: manifestURL.path,
        manifestSHA256: SHA256Digest.hex(manifestData),
        ownerApproval: EvaluationLearningArtifactBinding(
          path: ownerApprovalURL.path,
          sha256: SHA256Digest.hex(approvalData)
        )
      ),
      authorization: EvaluationLearningOperationAuthorization(
        eventPath: eventURL.path,
        eventSHA256: SHA256Digest.hex(eventData)
      ),
      invocationCoreDigest: invocationCoreDigest,
      carrierSHA256: carrierSHA256,
      providerCallID: providerCallID,
      taskRoute: taskRoute,
      evaluatorRoute: evaluatorRoute,
      reflectorRoute: reflectorRoute
    )
  }
}

private func makeEvaluationLearningAdmissionFixture(
  operationKind: EvaluationLearningOperationKind = .evaluator,
  eventMutation: String? = nil,
  approvalBudgetMutation: String? = nil
) throws -> EvaluationLearningAdmissionFixture {
  let root = try makeEvaluationTestRoot()
  let liveRun = root.appendingPathComponent("live-run", isDirectory: true)
  let events = liveRun.appendingPathComponent("events", isDirectory: true)
  try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: liveRun, withIntermediateDirectories: true)

  let taskRoute = EvaluationLearningRouteBinding(
    providerReference: "openai-chatgpt/gpt-5.6-sol",
    wireModel: "gpt-5.6-sol",
    retryBudget: 1,
    maxOutputTokens: 4_096,
    maxOutputUTF8Bytes: 32_768,
    maxOutputGraphemes: 16_384
  )
  let evaluatorRoute = EvaluationLearningRouteBinding(
    providerReference: "openai-chatgpt/gpt-5.6-sol",
    wireModel: "gpt-5.6-sol",
    retryBudget: 3,
    maxOutputTokens: 512,
    maxOutputUTF8Bytes: 2_048,
    maxOutputGraphemes: 2_048
  )
  let reflectorRoute = EvaluationLearningRouteBinding(
    providerReference: "openai-chatgpt/gpt-5.6-sol",
    wireModel: "gpt-5.6-sol",
    retryBudget: 3,
    maxOutputTokens: 768,
    maxOutputUTF8Bytes: 3_072,
    maxOutputGraphemes: 3_072
  )
  let budgets: [String: Any] = [
    "task_attempts": 1,
    "evaluator_calls": 2,
    "reflector_calls": 3,
    "responses_sends": 4,
    "accounted_tokens": 5,
  ]
  let executableURL = root.appendingPathComponent("claw-eval")
  let executableData = Data("frozen executable".utf8)
  try executableData.write(to: executableURL)
  let manifestObject: [String: Any] = [
    "budgets": budgets,
    "swift_execution": [
      "evaluator_route": routeObject(evaluatorRoute),
      "executable_sha256": SHA256Digest.hex(executableData),
      "missing_usage_token_proxy": 132_768,
      "reflector_route": routeObject(reflectorRoute),
      "task_route": routeObject(taskRoute),
    ],
  ]
  let manifestURL = root.appendingPathComponent("manifest.json")
  let manifestData = try EvaluationCanonicalJSON.data(fromJSONObject: manifestObject)
  try manifestData.write(to: manifestURL)
  let manifestSHA256 = SHA256Digest.hex(manifestData)
  var approvalBudgets = budgets
  if let approvalBudgetMutation {
    approvalBudgets[approvalBudgetMutation] = 9
  }
  let ownerApprovalURL = root.appendingPathComponent("owner-budget-approval.json")
  let ownerApprovalData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "approved_at": "2026-08-29T00:00:00Z",
    "budgets": approvalBudgets,
    "expected_freeze_commit": String(repeating: "a", count: 40),
    "manifest_sha256": manifestSHA256,
    "owner_identity": "owner-01",
    "schema_version": 1,
  ])
  try ownerApprovalData.write(to: ownerApprovalURL)
  let invocationCoreDigest = String(repeating: "d", count: 64)
  let carrierSHA256 = String(repeating: "e", count: 64)
  let providerCallID = ProviderCallID(rawValue: "00000000-0000-0000-0000-000000000001")
  var payload: [String: Any] = [
    "attempt_generation": 1,
    "carrier_digest": carrierSHA256,
    "freeze_commit": String(repeating: "a", count: 40),
    "invocation_core_digest": invocationCoreDigest,
    "job_id": "scheduled-learning-job-01",
    "manifest_digest": manifestSHA256,
    "operation_id": "evaluation-run-01",
    "operation_kind": operationKind.rawValue,
    "provider_call_id": providerCallID.rawValue,
    "route_digest": SHA256Digest.hex(
      try EvaluationCanonicalJSON.data(
        encoding: route(
          for: operationKind,
          task: taskRoute,
          evaluator: evaluatorRoute,
          reflector: reflectorRoute
        )
      )
    ),
  ]
  if let eventMutation {
    payload[eventMutation] =
      eventMutation == "provider_call_id"
      ? "00000000-0000-0000-0000-000000000002" : String(repeating: "f", count: 64)
  }
  let eventURL = events.appendingPathComponent("000004.json")
  let eventData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "kind": "operation_started",
    "occurred_at": "2026-08-29T00:00:00Z",
    "payload": payload,
    "schema_version": 1,
    "sequence": 4,
  ])
  try eventData.write(to: eventURL)

  return EvaluationLearningAdmissionFixture(
    root: root,
    manifestURL: manifestURL,
    ownerApprovalURL: ownerApprovalURL,
    executableURL: executableURL,
    manifest: EvaluationLearningManifestBinding(
      repositoryRoot: root.path,
      evaluationRoot: liveRun.path,
      manifestPath: manifestURL.path,
      manifestSHA256: manifestSHA256,
      ownerApproval: EvaluationLearningArtifactBinding(
        path: ownerApprovalURL.path,
        sha256: SHA256Digest.hex(ownerApprovalData)
      )
    ),
    authorization: EvaluationLearningOperationAuthorization(
      eventPath: eventURL.path,
      eventSHA256: SHA256Digest.hex(eventData)
    ),
    invocationCoreDigest: invocationCoreDigest,
    carrierSHA256: carrierSHA256,
    providerCallID: providerCallID,
    taskRoute: taskRoute,
    evaluatorRoute: evaluatorRoute,
    reflectorRoute: reflectorRoute
  )
}

private func routeObject(_ route: EvaluationLearningRouteBinding) -> [String: Any] {
  [
    "max_output_graphemes": route.maxOutputGraphemes,
    "max_output_tokens": route.maxOutputTokens,
    "max_output_utf8_bytes": route.maxOutputUTF8Bytes,
    "provider_reference": route.providerReference,
    "retry_budget": route.retryBudget,
    "wire_model": route.wireModel,
  ]
}

private func route(
  for kind: EvaluationLearningOperationKind,
  task: EvaluationLearningRouteBinding,
  evaluator: EvaluationLearningRouteBinding,
  reflector: EvaluationLearningRouteBinding
) -> EvaluationLearningRouteBinding {
  switch kind {
  case .task:
    task
  case .evaluator:
    evaluator
  case .reflector:
    reflector
  }
}

private struct StaticEvaluationLearningAdmissionVerifier: EvaluationLearningAdmissionVerifying {
  let context: EvaluationLearningAdmissionContext

  func verify(
    manifest _: EvaluationLearningManifestBinding,
    authorization _: EvaluationLearningOperationAuthorization,
    invocationCoreDigest _: String,
    carrierSHA256 _: String,
    providerCallID _: ProviderCallID,
    kind _: EvaluationLearningOperationKind
  ) async throws -> EvaluationLearningAdmissionContext {
    context
  }
}
