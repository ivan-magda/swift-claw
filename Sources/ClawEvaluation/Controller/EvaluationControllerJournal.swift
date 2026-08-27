import ClawCore
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

enum EvaluationControllerJournalEventKind: String, Codable, Sendable, Equatable {
  case batchStarted = "batch_started"
  case launchReserved = "launch_reserved"
  case launchCompleted = "launch_completed"
  case launchInterrupted = "launch_interrupted"
  case launchRejected = "launch_rejected"
  case batchCompleted = "batch_completed"
  case batchIncomplete = "batch_incomplete"
}

struct EvaluationControllerJournalEvent: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let eventID: UUID
  package let kind: EvaluationControllerJournalEventKind
  package let manifestSHA256: String
  package let freezeCommit: String
  package let fixedTimestamp: String
  package let invocationID: UUID?
  package let invocationCoreSHA256: String?
  package let attemptIDs: [String]
  package let reservedResponsesSends: Int
  package let reservedAccountedTokens: Int
  package let observedResponsesSends: Int?
  package let observedFileReads: Int?
  package let observedAccountedTokens: Int?
  package let processID: Int32?

  package init(
    eventID: UUID = UUID(),
    kind: EvaluationControllerJournalEventKind,
    manifestSHA256: String,
    freezeCommit: String,
    fixedTimestamp: String,
    invocationID: UUID? = nil,
    invocationCoreSHA256: String? = nil,
    attemptIDs: [String] = [],
    reservedResponsesSends: Int = 0,
    reservedAccountedTokens: Int = 0,
    observedResponsesSends: Int? = nil,
    observedFileReads: Int? = nil,
    observedAccountedTokens: Int? = nil,
    processID: Int32? = nil
  ) {
    schemaVersion = PageEvaluationContract.schemaVersion
    self.eventID = eventID
    self.kind = kind
    self.manifestSHA256 = manifestSHA256
    self.freezeCommit = freezeCommit
    self.fixedTimestamp = fixedTimestamp
    self.invocationID = invocationID
    self.invocationCoreSHA256 = invocationCoreSHA256
    self.attemptIDs = attemptIDs
    self.reservedResponsesSends = reservedResponsesSends
    self.reservedAccountedTokens = reservedAccountedTokens
    self.observedResponsesSends = observedResponsesSends
    self.observedFileReads = observedFileReads
    self.observedAccountedTokens = observedAccountedTokens
    self.processID = processID
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case eventID = "event_id"
    case kind
    case manifestSHA256 = "manifest_sha256"
    case freezeCommit = "freeze_commit"
    case fixedTimestamp = "fixed_timestamp"
    case invocationID = "invocation_id"
    case invocationCoreSHA256 = "invocation_core_sha256"
    case attemptIDs = "attempt_ids"
    case reservedResponsesSends = "reserved_responses_sends"
    case reservedAccountedTokens = "reserved_accounted_tokens"
    case observedResponsesSends = "observed_responses_sends"
    case observedFileReads = "observed_file_reads"
    case observedAccountedTokens = "observed_accounted_tokens"
    case processID = "process_id"
  }
}

/// A deliberately non-resumable, append-only controller ledger. A process crash leaves the ledger
/// behind, including the conservative pre-launch debit; the same approved manifest is then refused
/// rather than silently resetting attempt/send/token state.
struct EvaluationControllerJournal: Sendable {
  package let url: URL
  package let manifestSHA256: String
  package let freezeCommit: String
  package let fixedTimestamp: String

  package static func startNew(
    evaluationRoot: URL,
    manifestSHA256: String,
    freezeCommit: String,
    fixedTimestamp: String,
    journalName: String
  ) throws -> Self {
    let directory = evaluationRoot.appendingPathComponent("journal", isDirectory: true)
    let url = directory.appendingPathComponent(journalName, isDirectory: false)
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [evaluationRoot])
    try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [url])
    let descriptor = open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw EvaluationControllerJournalError.sameManifestContinuationRefused
      }
      throw EvaluationControllerJournalError.exclusiveCreateFailed(errno)
    }
    do {
      try EvaluationPathSecurity.secureCreatedRegularSingleLinkFile(
        descriptor: descriptor,
        at: url,
        permissions: S_IRUSR | S_IWUSR
      )
      guard fsync(descriptor) == 0 else {
        throw EvaluationControllerJournalError.exclusiveCreateFailed(errno)
      }
    } catch {
      _ = close(descriptor)
      throw error
    }
    guard close(descriptor) == 0 else {
      throw EvaluationControllerJournalError.exclusiveCreateFailed(errno)
    }
    let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard directoryDescriptor >= 0 else {
      throw EvaluationControllerJournalError.directorySyncFailed(errno)
    }
    guard fsync(directoryDescriptor) == 0 else {
      let code = errno
      _ = close(directoryDescriptor)
      throw EvaluationControllerJournalError.directorySyncFailed(code)
    }
    guard close(directoryDescriptor) == 0 else {
      throw EvaluationControllerJournalError.directorySyncFailed(errno)
    }
    let journal = Self(
      url: url,
      manifestSHA256: manifestSHA256,
      freezeCommit: freezeCommit,
      fixedTimestamp: fixedTimestamp
    )
    try journal.append(kind: .batchStarted)
    return journal
  }

  @discardableResult
  package func reserve(
    invocationID: UUID,
    invocationCoreSHA256: String,
    attemptIDs: [String],
    maximumResponsesSends: Int
  ) throws -> EvaluationControllerJournalEvent {
    let proxy = SaturatingArithmetic.product(
      maximumResponsesSends,
      PageEvaluationContract.missingUsageTokenProxy
    )
    return try append(
      kind: .launchReserved,
      invocationID: invocationID,
      invocationCoreSHA256: invocationCoreSHA256,
      attemptIDs: attemptIDs,
      reservedResponsesSends: maximumResponsesSends,
      reservedAccountedTokens: proxy
    )
  }

  @discardableResult
  package func recordLaunch(
    kind: EvaluationControllerJournalEventKind,
    invocationID: UUID,
    attemptIDs: [String],
    observedResponsesSends: Int?,
    observedFileReads: Int? = nil,
    observedAccountedTokens: Int?,
    processID: Int32?
  ) throws -> EvaluationControllerJournalEvent {
    precondition(kind == .launchCompleted || kind == .launchInterrupted || kind == .launchRejected)
    return try append(
      kind: kind,
      invocationID: invocationID,
      attemptIDs: attemptIDs,
      observedResponsesSends: observedResponsesSends,
      observedFileReads: observedFileReads,
      observedAccountedTokens: observedAccountedTokens,
      processID: processID
    )
  }

  @discardableResult
  package func finish(incomplete: Bool) throws -> EvaluationControllerJournalEvent {
    try append(kind: incomplete ? .batchIncomplete : .batchCompleted)
  }

  package static func authorize(
    _ authorization: EvaluationWorkerAuthorization,
    invocationID: UUID,
    invocationCoreSHA256: String,
    attemptIDs: [String],
    manifestSHA256: String,
    freezeCommit: String,
    fixedTimestamp: String,
    evaluationRoot: URL
  ) throws {
    try authorization.validate(
      invocationID: invocationID,
      invocationCoreSHA256: invocationCoreSHA256
    )
    let journalURL = URL(fileURLWithPath: authorization.journalPath).standardizedFileURL
    guard
      EvaluationPathSecurity.isStrictlyContained(
        journalURL,
        under: evaluationRoot.standardizedFileURL
      )
    else {
      throw EvaluationControllerJournalError.authorizationMismatch
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [journalURL.deletingLastPathComponent(), journalURL]
    )
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: journalURL)
    guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
      throw EvaluationControllerJournalError.authorizationMismatch
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let events = try lines.map { line in
      let raw = Data(line.utf8) + Data([0x0A])
      let event = try JSONDecoder().decode(
        EvaluationControllerJournalEvent.self,
        from: raw
      )
      guard try EvaluationCanonicalJSON.data(encoding: event) == raw else {
        throw EvaluationControllerJournalError.authorizationMismatch
      }
      return event
    }
    let reservation = authorization.reservation
    let expectedSends: Int
    switch attemptIDs.count {
    case 1: expectedSends = PageEvaluationContract.maximumResponsesSendsPerAttempt
    case PageEvaluationContract.canaryAttemptsPerProcess:
      expectedSends =
        PageEvaluationContract.canaryAttemptsPerProcess
        * PageEvaluationContract.maximumResponsesSendsPerAttempt
    default: throw EvaluationControllerJournalError.authorizationMismatch
    }
    let expectedTokens = SaturatingArithmetic.product(
      expectedSends,
      PageEvaluationContract.missingUsageTokenProxy
    )
    guard
      Set(events.map(\.eventID)).count == events.count,
      events.filter({ $0.kind == .launchReserved && $0.invocationID == invocationID }).count == 1,
      let startedIndex = events.firstIndex(where: { $0.kind == .batchStarted }),
      let reservationIndex = events.firstIndex(of: reservation),
      startedIndex < reservationIndex
    else {
      throw EvaluationControllerJournalError.authorizationMismatch
    }
    guard
      reservation.manifestSHA256 == manifestSHA256,
      reservation.freezeCommit == freezeCommit,
      reservation.fixedTimestamp == fixedTimestamp,
      reservation.invocationCoreSHA256 == invocationCoreSHA256,
      reservation.attemptIDs == attemptIDs,
      reservation.reservedResponsesSends == expectedSends,
      reservation.reservedAccountedTokens == expectedTokens,
      events.filter({ $0 == reservation }).count == 1,
      events.contains(where: {
        $0.kind == .batchStarted
          && $0.manifestSHA256 == manifestSHA256
          && $0.freezeCommit == freezeCommit
          && $0.fixedTimestamp == fixedTimestamp
      }),
      events.contains(where: {
        $0.invocationID == invocationID
          && ($0.kind == .launchCompleted || $0.kind == .launchInterrupted
            || $0.kind == .launchRejected)
      }) == false
    else {
      throw EvaluationControllerJournalError.authorizationMismatch
    }
  }

  @discardableResult
  private func append(
    kind: EvaluationControllerJournalEventKind,
    invocationID: UUID? = nil,
    invocationCoreSHA256: String? = nil,
    attemptIDs: [String] = [],
    reservedResponsesSends: Int = 0,
    reservedAccountedTokens: Int = 0,
    observedResponsesSends: Int? = nil,
    observedFileReads: Int? = nil,
    observedAccountedTokens: Int? = nil,
    processID: Int32? = nil
  ) throws -> EvaluationControllerJournalEvent {
    let event = EvaluationControllerJournalEvent(
      kind: kind,
      manifestSHA256: manifestSHA256,
      freezeCommit: freezeCommit,
      fixedTimestamp: fixedTimestamp,
      invocationID: invocationID,
      invocationCoreSHA256: invocationCoreSHA256,
      attemptIDs: attemptIDs,
      reservedResponsesSends: reservedResponsesSends,
      reservedAccountedTokens: reservedAccountedTokens,
      observedResponsesSends: observedResponsesSends,
      observedFileReads: observedFileReads,
      observedAccountedTokens: observedAccountedTokens,
      processID: processID
    )
    let data = try EvaluationCanonicalJSON.data(encoding: event)
    try EvaluationPathSecurity.appendAndSynchronize(data, toRegularSingleLinkFileAt: url)
    return event
  }

}

enum EvaluationControllerJournalError: Error, Sendable, Equatable {
  case sameManifestContinuationRefused
  case exclusiveCreateFailed(Int32)
  case directorySyncFailed(Int32)
  case authorizationMismatch
}
