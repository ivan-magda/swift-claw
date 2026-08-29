import ClawAgent
import ClawCore
import Foundation

package protocol EvaluationLearningAdmissionVerifying: Sendable {
  func verify(
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization,
    invocationCoreDigest: String,
    carrierSHA256: String,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind
  ) async throws -> EvaluationLearningAdmissionContext
}

package struct EvaluationLearningAdmissionContext: Sendable, Equatable {
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let manifestSHA256: String
  package let freezeCommit: String
  package let executableSHA256: String
  package let missingUsageTokenProxy: Int
  package let budgets: EvaluationLearningApprovedBudgets
  package let route: EvaluationLearningRouteBinding

  package init(
    jobID: String,
    operationID: String,
    attemptGeneration: Int,
    providerCallID: ProviderCallID,
    manifestSHA256: String,
    freezeCommit: String,
    executableSHA256: String,
    missingUsageTokenProxy: Int,
    budgets: EvaluationLearningApprovedBudgets,
    route: EvaluationLearningRouteBinding
  ) {
    self.jobID = jobID
    self.operationID = operationID
    self.attemptGeneration = attemptGeneration
    self.providerCallID = providerCallID
    self.manifestSHA256 = manifestSHA256
    self.freezeCommit = freezeCommit
    self.executableSHA256 = executableSHA256
    self.missingUsageTokenProxy = missingUsageTokenProxy
    self.budgets = budgets
    self.route = route
  }
}

package struct EvaluationLearningLiveAdmission: Sendable {
  package let verifier: any EvaluationLearningAdmissionVerifying
  package let manifest: EvaluationLearningManifestBinding
  package let authorization: EvaluationLearningOperationAuthorization
  package let invocationCoreDigest: String
  package let carrierSHA256: String
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let initial: EvaluationLearningAdmissionContext

  package init(
    verifier: any EvaluationLearningAdmissionVerifying,
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization,
    invocationCoreDigest: String,
    carrierSHA256: String,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind,
    initial: EvaluationLearningAdmissionContext
  ) {
    self.verifier = verifier
    self.manifest = manifest
    self.authorization = authorization
    self.invocationCoreDigest = invocationCoreDigest
    self.carrierSHA256 = carrierSHA256
    self.providerCallID = providerCallID
    self.kind = kind
    self.initial = initial
  }

  package func evaluate() async -> ProviderRoundTripAdmission {
    do {
      let refreshed = try await verifier.verify(
        manifest: manifest,
        authorization: authorization,
        invocationCoreDigest: invocationCoreDigest,
        carrierSHA256: carrierSHA256,
        providerCallID: providerCallID,
        kind: kind
      )
      return refreshed == initial ? .allow : .deny(cap: "evaluation-learning-integrity")
    } catch {
      return .deny(cap: "evaluation-learning-integrity")
    }
  }
}

package struct EvaluationLearningAdmissionVerifier: EvaluationLearningAdmissionVerifying {
  private let runningExecutablePath: @Sendable () -> String
  private let readFile: @Sendable (URL) throws -> Data

  package init(
    runningExecutablePath: @escaping @Sendable () -> String = { CommandLine.arguments[0] },
    readFile: @escaping @Sendable (URL) throws -> Data = { url in
      try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    }
  ) {
    self.runningExecutablePath = runningExecutablePath
    self.readFile = readFile
  }

  package func verify(
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization,
    invocationCoreDigest: String,
    carrierSHA256: String,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind
  ) async throws -> EvaluationLearningAdmissionContext {
    try Self.validate(binding: manifest, authorization: authorization)
    guard
      SHA256Digest.isCanonicalHex(invocationCoreDigest),
      SHA256Digest.isCanonicalHex(carrierSHA256),
      Self.isCanonicalProviderCallID(providerCallID)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }

    let manifestURL = URL(fileURLWithPath: manifest.manifestPath)
    let manifestData = try readFile(manifestURL)
    guard SHA256Digest.hex(manifestData) == manifest.manifestSHA256 else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    let manifestObject = try EvaluationLearningClosedJSON.object(from: manifestData)
    let projection = try Self.manifestProjection(from: manifestData, object: manifestObject)

    let approvalURL = URL(fileURLWithPath: manifest.ownerApproval.path)
    let approvalData = try readFile(approvalURL)
    guard SHA256Digest.hex(approvalData) == manifest.ownerApproval.sha256 else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    let approvalObject = try EvaluationLearningClosedJSON.object(from: approvalData)
    try Self.requireExactKeys(
      approvalObject,
      keys: [
        "schema_version", "manifest_sha256", "expected_freeze_commit", "budgets", "owner_identity",
        "approved_at",
      ]
    )
    let approval = try EvaluationLearningClosedJSON.decode(
      EvaluationLearningOwnerApprovalProjection.self,
      from: approvalData,
      object: approvalObject
    )
    try Self.requireExactObjectKeys(
      in: approvalObject,
      path: ["budgets"],
      keys: [
        "task_attempts", "evaluator_calls", "reflector_calls", "responses_sends",
        "accounted_tokens",
      ]
    )
    try Self.validate(approval: approval, matching: manifest, projection: projection)

    let eventURL = URL(fileURLWithPath: authorization.eventPath)
    let eventData = try readFile(eventURL)
    guard SHA256Digest.hex(eventData) == authorization.eventSHA256 else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    let eventObject = try EvaluationLearningClosedJSON.object(from: eventData)
    let event = try Self.operationStartedEvent(from: eventData, object: eventObject)

    let executableData = try readFile(URL(fileURLWithPath: runningExecutablePath()))
    guard SHA256Digest.hex(executableData) == projection.executableSHA256 else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }

    let route = projection.route(for: kind)
    guard
      event.payload.operationKind == kind,
      event.payload.carrierDigest == carrierSHA256,
      event.payload.invocationCoreDigest == invocationCoreDigest,
      event.payload.providerCallID == providerCallID,
      event.payload.manifestDigest == manifest.manifestSHA256,
      event.payload.freezeCommit == approval.expectedFreezeCommit,
      event.payload.routeDigest
        == SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: route))
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }

    return EvaluationLearningAdmissionContext(
      jobID: event.payload.jobID,
      operationID: event.payload.operationID,
      attemptGeneration: event.payload.attemptGeneration,
      providerCallID: providerCallID,
      manifestSHA256: manifest.manifestSHA256,
      freezeCommit: approval.expectedFreezeCommit,
      executableSHA256: projection.executableSHA256,
      missingUsageTokenProxy: projection.missingUsageTokenProxy,
      budgets: projection.budgets,
      route: route
    )
  }
}

private extension EvaluationLearningAdmissionVerifier {
  struct ManifestDocument: Decodable, Encodable {
    let budgets: EvaluationLearningApprovedBudgets
    let swiftExecution: SwiftExecution

    enum CodingKeys: String, CodingKey {
      case budgets
      case swiftExecution = "swift_execution"
    }
  }

  struct SwiftExecution: Decodable, Encodable {
    let evaluatorRoute: EvaluationLearningRouteBinding
    let executableSHA256: String
    let missingUsageTokenProxy: Int
    let reflectorRoute: EvaluationLearningRouteBinding
    let taskRoute: EvaluationLearningRouteBinding

    enum CodingKeys: String, CodingKey {
      case evaluatorRoute = "evaluator_route"
      case executableSHA256 = "executable_sha256"
      case missingUsageTokenProxy = "missing_usage_token_proxy"
      case reflectorRoute = "reflector_route"
      case taskRoute = "task_route"
    }
  }

  struct OperationStartedEvent: Decodable, Encodable {
    let kind: String
    let occurredAt: String
    let payload: OperationPayload
    let schemaVersion: Int
    let sequence: Int

    enum CodingKeys: String, CodingKey {
      case kind
      case occurredAt = "occurred_at"
      case payload
      case schemaVersion = "schema_version"
      case sequence
    }
  }

  struct OperationPayload: Decodable, Encodable {
    let attemptGeneration: Int
    let carrierDigest: String
    let freezeCommit: String
    let invocationCoreDigest: String
    let jobID: String
    let manifestDigest: String
    let operationID: String
    let operationKind: EvaluationLearningOperationKind
    let providerCallID: ProviderCallID
    let routeDigest: String

    enum CodingKeys: String, CodingKey {
      case attemptGeneration = "attempt_generation"
      case carrierDigest = "carrier_digest"
      case freezeCommit = "freeze_commit"
      case invocationCoreDigest = "invocation_core_digest"
      case jobID = "job_id"
      case manifestDigest = "manifest_digest"
      case operationID = "operation_id"
      case operationKind = "operation_kind"
      case providerCallID = "provider_call_id"
      case routeDigest = "route_digest"
    }
  }

  static func validate(
    binding: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization
  ) throws {
    guard
      SHA256Digest.isCanonicalHex(binding.manifestSHA256),
      SHA256Digest.isCanonicalHex(binding.ownerApproval.sha256),
      SHA256Digest.isCanonicalHex(authorization.eventSHA256)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    let repository = try absoluteURL(binding.repositoryRoot)
    let evaluation = try absoluteURL(binding.evaluationRoot)
    let manifest = try absoluteURL(binding.manifestPath)
    let approval = try absoluteURL(binding.ownerApproval.path)
    let event = try absoluteURL(authorization.eventPath)
    guard
      EvaluationPathSecurity.isStrictlyContained(evaluation, under: repository),
      EvaluationPathSecurity.isStrictlyContained(manifest, under: repository),
      EvaluationPathSecurity.isStrictlyContained(approval, under: repository),
      EvaluationPathSecurity.isStrictlyContained(event, under: evaluation)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [repository, evaluation, manifest, approval, event]
    )
  }

  static func manifestProjection(
    from data: Data,
    object: [String: Any]
  ) throws -> EvaluationLearningManifestProjection {
    guard object["budgets"] != nil, object["swift_execution"] != nil else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    let document = try EvaluationLearningClosedJSON.decode(
      ManifestDocument.self,
      from: data,
      object: object
    )
    try requireExactObjectKeys(
      in: object,
      path: ["swift_execution"],
      keys: [
        "evaluator_route", "executable_sha256", "missing_usage_token_proxy", "reflector_route",
        "task_route",
      ]
    )
    try requireExactObjectKeys(
      in: object,
      path: ["budgets"],
      keys: [
        "task_attempts", "evaluator_calls", "reflector_calls", "responses_sends",
        "accounted_tokens",
      ]
    )
    for name in ["task_route", "evaluator_route", "reflector_route"] {
      try requireExactObjectKeys(
        in: object,
        path: ["swift_execution", name],
        keys: [
          "provider_reference", "wire_model", "retry_budget", "max_output_tokens",
          "max_output_utf8_bytes", "max_output_graphemes",
        ]
      )
    }
    let execution = document.swiftExecution
    let projection = EvaluationLearningManifestProjection(
      executableSHA256: execution.executableSHA256,
      missingUsageTokenProxy: execution.missingUsageTokenProxy,
      budgets: document.budgets,
      taskRoute: execution.taskRoute,
      evaluatorRoute: execution.evaluatorRoute,
      reflectorRoute: execution.reflectorRoute
    )
    guard
      SHA256Digest.isCanonicalHex(projection.executableSHA256),
      projection.missingUsageTokenProxy > 0,
      projection.budgets.isPositive
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    try validate(route: projection.taskRoute)
    try validate(route: projection.evaluatorRoute)
    try validate(route: projection.reflectorRoute)
    return projection
  }

  static func operationStartedEvent(
    from data: Data,
    object: [String: Any]
  ) throws -> OperationStartedEvent {
    try requireExactKeys(
      object,
      keys: ["kind", "occurred_at", "payload", "schema_version", "sequence"]
    )
    let event = try EvaluationLearningClosedJSON.decode(
      OperationStartedEvent.self,
      from: data,
      object: object
    )
    try requireExactObjectKeys(
      in: object,
      path: ["payload"],
      keys: [
        "attempt_generation", "carrier_digest", "freeze_commit", "invocation_core_digest", "job_id",
        "manifest_digest", "operation_id", "operation_kind", "provider_call_id", "route_digest",
      ]
    )
    guard
      event.kind == "operation_started",
      event.schemaVersion == 1,
      event.sequence > 0,
      event.payload.attemptGeneration > 0,
      event.payload.jobID.isEmpty == false,
      event.payload.operationID.isEmpty == false,
      isUTCTimestamp(event.occurredAt),
      SHA256Digest.isCanonicalHex(event.payload.carrierDigest),
      SHA256Digest.isCanonicalHex(event.payload.invocationCoreDigest),
      SHA256Digest.isCanonicalHex(event.payload.manifestDigest),
      SHA256Digest.isCanonicalHex(event.payload.routeDigest),
      isCommit(event.payload.freezeCommit),
      isCanonicalProviderCallID(event.payload.providerCallID)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    return event
  }

  static func validate(
    approval: EvaluationLearningOwnerApprovalProjection,
    matching manifest: EvaluationLearningManifestBinding,
    projection: EvaluationLearningManifestProjection
  ) throws {
    guard
      approval.schemaVersion == 1,
      approval.manifestSHA256 == manifest.manifestSHA256,
      approval.budgets == projection.budgets,
      approval.budgets.isPositive,
      approval.ownerIdentity.isEmpty == false,
      isCommit(approval.expectedFreezeCommit),
      isUTCTimestamp(approval.approvedAt)
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
  }

  static func validate(route: EvaluationLearningRouteBinding) throws {
    guard
      route.providerReference.isEmpty == false,
      route.wireModel.isEmpty == false,
      route.retryBudget > 0,
      route.maxOutputTokens > 0,
      route.maxOutputUTF8Bytes > 0,
      route.maxOutputGraphemes > 0
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
  }

  static func absoluteURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    guard path.hasPrefix("/"), url.standardizedFileURL.path == path else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    return url
  }

  static func requireExactKeys(_ object: [String: Any], keys: Set<String>) throws {
    guard Set(object.keys) == keys else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
  }

  static func requireExactObjectKeys(
    in root: [String: Any],
    path: [String],
    keys: Set<String>
  ) throws {
    var value: Any = root
    for component in path {
      guard let object = value as? [String: Any], let next = object[component] else {
        throw EvaluationLearningAdmissionError.invalidJSON
      }
      value = next
    }
    guard let object = value as? [String: Any], Set(object.keys) == keys else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
  }

  static func isCommit(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
  }

  static func isUTCTimestamp(_ value: String) -> Bool {
    value.hasSuffix("Z") && ISO8601DateFormatter().date(from: value) != nil
  }

  static func isCanonicalProviderCallID(_ value: ProviderCallID) -> Bool {
    guard let identifier = UUID(uuidString: value.rawValue) else {
      return false
    }
    return identifier.uuidString.lowercased() == value.rawValue
  }
}

private extension EvaluationLearningManifestProjection {
  func route(for kind: EvaluationLearningOperationKind) -> EvaluationLearningRouteBinding {
    switch kind {
    case .task:
      taskRoute
    case .evaluator:
      evaluatorRoute
    case .reflector:
      reflectorRoute
    }
  }
}

private extension EvaluationLearningApprovedBudgets {
  var isPositive: Bool {
    taskAttempts > 0
      && evaluatorCalls > 0
      && reflectorCalls > 0
      && responsesSends > 0
      && accountedTokens > 0
  }
}
