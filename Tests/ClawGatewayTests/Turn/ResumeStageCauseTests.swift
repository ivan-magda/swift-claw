import ClawCore
import Foundation
import Testing

@testable import ClawGateway

/// A resume gives up in two places, and both read from SQLite before they reach the provider. What
/// the run records has to be what is actually known: the eligibility boundary buckets a storage
/// failure and an unfinished turn differently, so collapsing one into the other is wrong data, not
/// a harmless approximation.
@Suite struct ResumeStageCauseTests {
  @Test func aStorageFailureIsRecordedAsOneWhicheverStageRaisedIt() {
    // given / when / then — `resumeUsage` and the context snapshot both read the database, so
    // either stage can surface a store fault, and neither may file it under its generic cause
    #expect(ResumeStage.contextBuild.terminalCause(for: StoreError.diskFull) == .storageFailure)
    #expect(ResumeStage.turn.terminalCause(for: StoreError.diskFull) == .storageFailure)
  }

  @Test func anythingElseKeepsTheStagesOwnCause() {
    // given — a failure the store had no part in
    struct ProviderTrouble: Error {}

    // when / then — assembly leaves the turn unfinished; the round-trip itself is a provider fault
    #expect(ResumeStage.contextBuild.terminalCause(for: ProviderTrouble()) == .incomplete)
    #expect(ResumeStage.turn.terminalCause(for: ProviderTrouble()) == .providerFailure)
  }
}
