import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationControllerJournalTests {
  @Test func prelaunchJournalDebitsUnknownSendsAndRefusesSameManifestContinuation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = String(repeating: "a", count: 64)
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: root,
      manifestSHA256: manifest,
      freezeCommit: String(repeating: "b", count: 40),
      fixedTimestamp: "2026-08-26T00:00:00Z",
      journalName: "page-\(manifest).jsonl"
    )

    // when — reservation is durable before a worker could make either send.
    let reservation = try journal.reserve(
      invocationID: UUID(),
      invocationCoreSHA256: String(repeating: "c", count: 64),
      attemptIDs: ["attempt-1"],
      maximumResponsesSends: 2
    )

    // then
    #expect(reservation.reservedResponsesSends == 2)
    #expect(
      reservation.reservedAccountedTokens
        == 2 * PageEvaluationContract.missingUsageTokenProxy
    )
    let bytes = try Data(contentsOf: journal.url)
    #expect(String(decoding: bytes, as: UTF8.self).contains(#""kind":"launch_reserved""#))
    #expect(throws: EvaluationControllerJournalError.sameManifestContinuationRefused) {
      _ = try EvaluationControllerJournal.startNew(
        evaluationRoot: root,
        manifestSHA256: manifest,
        freezeCommit: String(repeating: "b", count: 40),
        fixedTimestamp: "2026-08-26T00:00:00Z",
        journalName: "page-\(manifest).jsonl"
      )
    }
    #expect(try Data(contentsOf: journal.url) == bytes)

    // A path substitution after creation cannot redirect a later append into another file.
    let external = root.appendingPathComponent("external-ledger.jsonl")
    let externalData = Data("must-not-change".utf8)
    try externalData.write(to: external)
    try FileManager.default.removeItem(at: journal.url)
    try FileManager.default.linkItem(at: external, to: journal.url)
    #expect(throws: EvaluationPathSecurityError.insecureFile(journal.url.lastPathComponent)) {
      _ = try journal.reserve(
        invocationID: UUID(),
        invocationCoreSHA256: String(repeating: "d", count: 64),
        attemptIDs: ["attempt-2"],
        maximumResponsesSends: 2
      )
    }
    #expect(try Data(contentsOf: external) == externalData)
  }

  @Test func workerAuthorizationMustMatchTheDurableControllerReservation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = String(repeating: "a", count: 64)
    let commit = String(repeating: "b", count: 40)
    let timestamp = "2026-08-26T00:00:00Z"
    let invocationID = UUID()
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: root,
      manifestSHA256: manifest,
      freezeCommit: commit,
      fixedTimestamp: timestamp,
      journalName: "page-\(manifest).jsonl"
    )
    let reservation = try journal.reserve(
      invocationID: invocationID,
      invocationCoreSHA256: String(repeating: "c", count: 64),
      attemptIDs: ["attempt-1"],
      maximumResponsesSends: 2
    )
    let authorization = EvaluationWorkerAuthorization(
      journalPath: journal.url.path,
      reservation: reservation,
      reservationSHA256: SHA256Digest.hex(
        try EvaluationCanonicalJSON.data(encoding: reservation)
      )
    )

    // when
    try EvaluationControllerJournal.authorize(
      authorization,
      invocationID: invocationID,
      invocationCoreSHA256: String(repeating: "c", count: 64),
      attemptIDs: ["attempt-1"],
      manifestSHA256: manifest,
      freezeCommit: commit,
      fixedTimestamp: timestamp,
      evaluationRoot: root
    )
    try journal.recordLaunch(
      kind: .launchCompleted,
      invocationID: invocationID,
      attemptIDs: ["attempt-1"],
      observedResponsesSends: 2,
      observedAccountedTokens: 1,
      processID: 42
    )
    let replayError = #expect(throws: EvaluationControllerJournalError.authorizationMismatch) {
      try EvaluationControllerJournal.authorize(
        authorization,
        invocationID: invocationID,
        invocationCoreSHA256: String(repeating: "c", count: 64),
        attemptIDs: ["attempt-1"],
        manifestSHA256: manifest,
        freezeCommit: commit,
        fixedTimestamp: timestamp,
        evaluationRoot: root
      )
    }
    let coreError = #expect(throws: EvaluationWorkerInvocationError.invalidAuthorization) {
      try authorization.validate(
        invocationID: invocationID,
        invocationCoreSHA256: String(repeating: "d", count: 64)
      )
    }
    let attemptError = #expect(throws: EvaluationControllerJournalError.authorizationMismatch) {
      try EvaluationControllerJournal.authorize(
        authorization,
        invocationID: invocationID,
        invocationCoreSHA256: String(repeating: "c", count: 64),
        attemptIDs: ["forged-attempt"],
        manifestSHA256: manifest,
        freezeCommit: commit,
        fixedTimestamp: timestamp,
        evaluationRoot: root
      )
    }

    // then — a terminal reservation cannot be replayed or rebound to another core/attempt.
    #expect(replayError != nil)
    #expect(coreError != nil)
    #expect(attemptError != nil)
  }
}
