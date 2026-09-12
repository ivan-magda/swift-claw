import ClawCore
import ClawData
import Foundation
import GRDB

enum ApprovedExecutionFixture {
  static func claim(
    queue: DatabaseQueue,
    inbound: InboundMessage,
    policyVersion: String,
    commit: SuspendedTurnCommit,
    actor: ApprovalResolutionActor,
    now: Date
  ) throws -> Approval {
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let approvals = ApprovalStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(inbound)
    let runID = try required(claim.runId)
    let sessionID = try required(claim.sessionId)
    let origin = try required(
      try runs.pickUp(runId: runID, policyVersion: policyVersion, now: now)
    )
    guard origin == .interactive else {
      throw StoreError.unexpected("Approval fixture did not create an interactive run")
    }
    let receipt = try runs.commitSuspendedTurn(
      runId: runID,
      sessionId: sessionID,
      commit: commit,
      now: now
    )
    let resolution = try approvals.approve(
      id: receipt.approvalId,
      currentPolicyVersion: policyVersion,
      actor: actor,
      now: now
    )
    guard case .approved(let approval) = resolution else {
      throw StoreError.unexpected("Approval fixture was not granted")
    }
    let execution = try runs.claimApprovedExecution(
      runId: approval.runId,
      observationMessageId: approval.observationMessageId,
      notResumableObservationContent: "The task was stopped before admission.",
      now: now
    )
    guard execution == .committed else {
      throw StoreError.unexpected("Approval fixture could not claim its approved execution")
    }
    return approval
  }

  static func required<Value>(_ value: Value?) throws -> Value {
    guard let value else {
      throw StoreError.unexpected("Approval fixture is missing a required value")
    }
    return value
  }
}
