import ClawCore
import Foundation
import Synchronization

struct EvaluationAttemptProgressEntry: Codable, Sendable, Equatable {
  let attemptID: String
  let configurationSHA256: String
  var responsesRequests: [EvaluationResponsesSend]
  var provenNotStartedResponsesSends: Int
  var credentialHTTPCalls: Int
  var fileReads: Int
  var accountedTokens: Int
  var usage: [EvaluationUsageRecord]

  enum CodingKeys: String, CodingKey {
    case attemptID = "attempt_id"
    case configurationSHA256 = "configuration_sha256"
    case responsesRequests = "responses_requests"
    case provenNotStartedResponsesSends = "proven_not_started_responses_sends"
    case credentialHTTPCalls = "credential_http_calls"
    case fileReads = "file_reads"
    case accountedTokens = "accounted_tokens"
    case usage
  }

  var responsesSends: Int { responsesRequests.count }
}

struct EvaluationAttemptProgressRecord: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let invocationID: UUID
  let invocationConfigurationSHA256: String
  let manifestSHA256: String
  var attempts: [EvaluationAttemptProgressEntry]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case invocationID = "invocation_id"
    case invocationConfigurationSHA256 = "invocation_configuration_sha256"
    case manifestSHA256 = "manifest_sha256"
    case attempts
  }

  func validate(
    invocationID: UUID,
    invocationConfigurationSHA256: String,
    configurations: [EvaluationAttemptConfiguration]
  ) throws {
    let expected = try Self.initialEntries(for: configurations)
    guard
      schemaVersion == PageEvaluationContract.schemaVersion,
      self.invocationID == invocationID,
      self.invocationConfigurationSHA256 == invocationConfigurationSHA256,
      manifestSHA256 == configurations.first?.approval.manifestSHA256,
      attempts.map(\.attemptID) == expected.map(\.attemptID),
      attempts.map(\.configurationSHA256) == expected.map(\.configurationSHA256),
      attempts.allSatisfy({ entry in
        (0...PageEvaluationContract.maximumResponsesSendsPerAttempt).contains(
          entry.responsesSends
        )
          && (0...PageEvaluationContract.runBudget.maxToolCalls).contains(entry.fileReads)
          && entry.provenNotStartedResponsesSends >= 0
          && entry.provenNotStartedResponsesSends <= entry.responsesSends
          && entry.credentialHTTPCalls >= 0
          && entry.usage.count
            <= entry.responsesSends - entry.provenNotStartedResponsesSends
          && Set(entry.usage.map(\.providerCallID)).count == entry.usage.count
          && entry.usage.allSatisfy({ usage in
            usage.promptTokens >= 0
              && usage.completionTokens >= 0
              && usage.totalTokens
                == SaturatingArithmetic.sum(usage.promptTokens, usage.completionTokens)
          })
          && entry.accountedTokens == Self.accountedTokens(for: entry)
      })
    else {
      throw EvaluationPagePipelineError.invalidBatch("attempt_progress_identity")
    }
  }

  static func configurationSHA256(
    _ configuration: EvaluationAttemptConfiguration
  ) throws -> String {
    SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: configuration))
  }

  static func initialEntries(
    for configurations: [EvaluationAttemptConfiguration]
  ) throws -> [EvaluationAttemptProgressEntry] {
    try configurations.map { configuration in
      EvaluationAttemptProgressEntry(
        attemptID: configuration.attemptID,
        configurationSHA256: try configurationSHA256(configuration),
        responsesRequests: [],
        provenNotStartedResponsesSends: 0,
        credentialHTTPCalls: 0,
        fileReads: 0,
        accountedTokens: 0,
        usage: []
      )
    }
  }

  static func accountedTokens(for entry: EvaluationAttemptProgressEntry) -> Int {
    EvaluationResultAccounting.accountedTokens(
      responsesSends: entry.responsesSends,
      provenNotStartedResponsesSends: entry.provenNotStartedResponsesSends,
      usage: entry.usage.map {
        EvaluationUsageAccountingRow(tokens: $0.totalTokens, isEstimated: $0.isEstimated)
      }
    )
  }
}

final class EvaluationAttemptProgressRecorder: @unchecked Sendable {
  private struct State: Sendable {
    var record: EvaluationAttemptProgressRecord
  }

  private let url: URL
  private let state: Mutex<State>

  private init(url: URL, record: EvaluationAttemptProgressRecord) {
    self.url = url
    self.state = Mutex(State(record: record))
  }

  static func start(
    invocation: EvaluationWorkerInvocation,
    configurations: [EvaluationAttemptConfiguration]
  ) throws -> Self {
    guard
      let first = configurations.first,
      configurations.allSatisfy({
        $0.resultURL.deletingLastPathComponent()
          == first.resultURL
          .deletingLastPathComponent()
      }),
      Set(configurations.map(\.attemptID)).count == configurations.count,
      Set(configurations.map(\.approval.manifestSHA256)).count == 1
    else {
      throw EvaluationPagePipelineError.invalidBatch("attempt_progress_configuration")
    }
    let record = EvaluationAttemptProgressRecord(
      schemaVersion: PageEvaluationContract.schemaVersion,
      invocationID: invocation.invocationID,
      invocationConfigurationSHA256: invocation.configurationSHA256,
      manifestSHA256: first.approval.manifestSHA256,
      attempts: try EvaluationAttemptProgressRecord.initialEntries(for: configurations)
    )
    try record.validate(
      invocationID: invocation.invocationID,
      invocationConfigurationSHA256: invocation.configurationSHA256,
      configurations: configurations
    )
    let recorder = Self(
      url: try url(invocationID: invocation.invocationID, configurations: configurations),
      record: record
    )
    try EvaluationDurablePublication.publishExclusive(
      EvaluationCanonicalJSON.data(encoding: record),
      to: recorder.url
    )
    return recorder
  }

  func recordResponsesSend(attemptID: String, request: EvaluationResponsesSend) throws {
    try update(attemptID: attemptID) { entry in
      guard entry.responsesSends < PageEvaluationContract.maximumResponsesSendsPerAttempt else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_send_cap")
      }
      guard request.sequence == entry.responsesSends + 1 else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_send_sequence")
      }
      entry.responsesRequests.append(request)
      entry.accountedTokens = EvaluationAttemptProgressRecord.accountedTokens(for: entry)
    }
  }

  func recordFileRead(attemptID: String) throws {
    try update(attemptID: attemptID) { entry in
      guard entry.fileReads < PageEvaluationContract.runBudget.maxToolCalls else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_file_read_cap")
      }
      entry.fileReads += 1
    }
  }

  func recordCredentialHTTPCall(attemptID: String) throws {
    try update(attemptID: attemptID) { entry in
      guard entry.credentialHTTPCalls < Int.max else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_credential_call_count")
      }
      entry.credentialHTTPCalls += 1
    }
  }

  func recordProvenNotStartedResponsesSends(attemptID: String, count: Int) throws {
    guard count >= 0 else {
      throw EvaluationPagePipelineError.invalidBatch("attempt_progress_no_start_count")
    }
    try update(attemptID: attemptID) { entry in
      guard
        entry.provenNotStartedResponsesSends <= entry.responsesSends,
        entry.usage.count <= entry.responsesSends - entry.provenNotStartedResponsesSends,
        count
          <= entry.responsesSends
          - entry.provenNotStartedResponsesSends
          - entry.usage.count
      else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_no_start_count")
      }
      entry.provenNotStartedResponsesSends += count
      entry.accountedTokens = EvaluationAttemptProgressRecord.accountedTokens(for: entry)
    }
  }

  func recordUsage(attemptID: String, usage: ProviderUsage) throws {
    try state.withLock { state in
      guard let index = state.record.attempts.firstIndex(where: { $0.attemptID == attemptID })
      else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_attempt")
      }
      var next = state
      guard
        next.record.attempts[index].provenNotStartedResponsesSends
          <= next.record.attempts[index].responsesSends,
        next.record.attempts[index].usage.contains(where: {
          $0.providerCallID == usage.providerCallID.rawValue
        }) == false,
        next.record.attempts[index].usage.count
          < next.record.attempts[index].responsesSends
          - next.record.attempts[index].provenNotStartedResponsesSends
      else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_usage_count")
      }
      next.record.attempts[index].usage.append(EvaluationUsageRecord(usage))
      next.record.attempts[index].accountedTokens =
        EvaluationAttemptProgressRecord.accountedTokens(
          for: next.record.attempts[index]
        )
      try publish(next.record)
      state = next
    }
  }

  static func loadIfPresent(
    invocationID: UUID,
    invocationConfigurationSHA256: String,
    configurations: [EvaluationAttemptConfiguration]
  ) throws -> EvaluationAttemptProgressRecord? {
    let url = try url(invocationID: invocationID, configurations: configurations)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let record = try EvaluationJSONFile.decode(EvaluationAttemptProgressRecord.self, from: url)
    try record.validate(
      invocationID: invocationID,
      invocationConfigurationSHA256: invocationConfigurationSHA256,
      configurations: configurations
    )
    return record
  }

  static func url(
    invocationID: UUID,
    configurations: [EvaluationAttemptConfiguration]
  ) throws -> URL {
    guard let first = configurations.first else {
      throw EvaluationPagePipelineError.invalidBatch("attempt_progress_configuration")
    }
    let directory = first.resultURL.deletingLastPathComponent()
    return directory.appendingPathComponent(
      "progress-\(invocationID.uuidString.lowercased()).json"
    )
  }

  private func update(
    attemptID: String,
    mutation: (inout EvaluationAttemptProgressEntry) throws -> Void
  ) throws {
    try state.withLock { state in
      guard let index = state.record.attempts.firstIndex(where: { $0.attemptID == attemptID })
      else {
        throw EvaluationPagePipelineError.invalidBatch("attempt_progress_attempt")
      }
      var next = state
      try mutation(&next.record.attempts[index])
      try publish(next.record)
      state = next
    }
  }

  private func publish(_ record: EvaluationAttemptProgressRecord) throws {
    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(encoding: record),
      to: url
    )
  }
}
