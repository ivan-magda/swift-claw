import ClawCore
import ClawTestSupport
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

/// The credential map's crash-safety seam: what a failed publication leaves behind, and what an
/// uncertain one is allowed to report. Every failpoint here names `llm-credentials.enc` explicitly —
/// a bare failpoint would fire on the runtime seal's own publications and abort these tests before
/// they reached the code they claim to exercise.
@Suite struct LLMCredentialStorePublicationTests {
  // MARK: - Pre-commit failure

  @Test(
    arguments: [
      SecureFilePublisher.Failpoint.Step.tempWrite,
      SecureFilePublisher.Failpoint.Step.fileSync,
      SecureFilePublisher.Failpoint.Step.commit,
    ]
  ) func aFailureBeforeTheCommitLeavesTheOldMapWhole(
    step: SecureFilePublisher.Failpoint.Step
  ) throws {
    // given — a map already holding a record for another provider, which the failed save must not
    // be able to damage.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let incumbent = makeCredential(accessToken: "incumbent-access")
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      incumbent,
      providerID: .openAIChatGPT
    )
    let settled = try Data(contentsOf: envelopeURL(in: stateRoot))

    // when
    let store = makeStore(stateRoot: stateRoot, failing: step)

    // then — `.publicationFailed`, not `.commitUncertain`: nothing claimed the name, so a caller is
    // free to retry as though the save never happened.
    #expect(throws: LLMCredentialStoreError.publicationFailed) {
      try store.save(makeCredential(accessToken: "doomed-access"), providerID: .openAIChatGPT)
    }

    // The failpoint fired on this publication and nowhere else: the envelope's bytes are the exact
    // ones that were there before, and the record that was stored still loads.
    #expect(try Data(contentsOf: envelopeURL(in: stateRoot)) == settled)
    #expect(
      try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
        == incumbent
    )
    #expect(try entryNames(in: stateRoot) == expectedFullStateRoot)
  }

  @Test func aFailureBeforeTheCommitOnAFirstSaveCreatesNoCredentialFile() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let store = makeStore(stateRoot: stateRoot, failing: .commit)

    // then — a stranded temp in the state root would be a 0600 copy of a live refresh token that
    // nothing will ever clean up.
    #expect(throws: LLMCredentialStoreError.publicationFailed) {
      try store.save(makeCredential(), providerID: .openAIChatGPT)
    }
    #expect(try entryNames(in: stateRoot) == [SecretFile.key, SecretFile.envelope].sorted())
  }

  // MARK: - Uncertain commit

  @Test func aCommitThatCannotBeProvenDurableIsNotReportedAsASavedCredential() throws {
    // given — the rotation case that matters: an old credential on disk, a new one being written.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let older = makeCredential(accessToken: "older-access")
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(older, providerID: .openAIChatGPT)
    let settled = try Data(contentsOf: envelopeURL(in: stateRoot))

    // when — the directory fsync fails on this entry, and keeps failing: the rename landed, so the
    // new bytes are visible, but nothing has proven a crash would not lose them.
    let newer = makeCredential(accessToken: "newer-access")
    let store = makeStore(stateRoot: stateRoot, failing: .directorySync)

    // then — visible is not durable. Returning here would hand a caller a credential that a crash
    // could revert, after the vendor already rotated the old one away.
    #expect(throws: LLMCredentialStoreError.commitUncertain) {
      try store.save(newer, providerID: .openAIChatGPT)
    }

    // The failpoint fired exactly where it was aimed: `.commitUncertain` is reachable only after
    // the rename, and the envelope on disk is no longer the one that was there before.
    #expect(try Data(contentsOf: envelopeURL(in: stateRoot)) != settled)
    #expect(
      try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
        == newer
    )
  }

  // MARK: - Uncertain-commit recovery

  @Test func recoveringACommitWhoseIntendedBytesAlreadyLandedSyncsRatherThanRepublishes() throws {
    // given — the ordinary uncertain commit: the rename took, only its durability is unproven.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let credential = makeCredential()
    try store.save(credential, providerID: .openAIChatGPT)
    let landed = try #require(SecureFilePublisher.facts(ofEntryAt: envelopeURL(in: stateRoot)))

    // when
    try store.recoverUncertainCommit(
      EncryptedLLMCredentialStore.CredentialMap(providers: [.openAIChatGPT: credential]),
      key: try openKey(in: stateRoot)
    )

    // then — the inode is the evidence of which branch ran: republishing would have renamed a new
    // one into place, so an unchanged identity proves the retry was the fsync alone.
    let after = try #require(SecureFilePublisher.facts(ofEntryAt: envelopeURL(in: stateRoot)))
    #expect(after.identity == landed.identity)
    #expect(try store.load(providerID: .openAIChatGPT) == credential)
  }

  @Test func recoveringACommitWhoseBytesAreAbsentRepublishesTheCompleteMap() throws {
    // given — the rename is not known to have happened at all, so the path may hold nothing.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let credential = makeCredential()
    let bystander = makeCredential(accessToken: "bystander-access")
    let intended = EncryptedLLMCredentialStore.CredentialMap(
      providers: [.openAIChatGPT: credential, syntheticProvider: bystander]
    )

    // when
    try store.recoverUncertainCommit(intended, key: try openKey(in: stateRoot))

    // then — the complete map, not just the record that prompted the write.
    #expect(try store.load(providerID: .openAIChatGPT) == credential)
    #expect(try store.load(providerID: syntheticProvider) == bystander)
    #expect(try entryNames(in: stateRoot) == expectedFullStateRoot)
  }

  @Test func recoveringACommitThatFindsAStaleMapRepublishesTheCompleteMap() throws {
    // given — the path holds the previous map: the rename did not take.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    try store.save(makeCredential(accessToken: "stale-access"), providerID: .openAIChatGPT)
    let stale = try #require(SecureFilePublisher.facts(ofEntryAt: envelopeURL(in: stateRoot)))

    // when
    let intended = makeCredential(accessToken: "intended-access")
    try store.recoverUncertainCommit(
      EncryptedLLMCredentialStore.CredentialMap(providers: [.openAIChatGPT: intended]),
      key: try openKey(in: stateRoot)
    )

    // then — a fresh inode is the evidence that this branch republished rather than blessing what
    // it found.
    let after = try #require(SecureFilePublisher.facts(ofEntryAt: envelopeURL(in: stateRoot)))
    #expect(after.identity != stale.identity)
    #expect(try store.load(providerID: .openAIChatGPT) == intended)
  }

  @Test func recoveringACommitOverAnUnreadableMapRepublishesRatherThanFailing() throws {
    // given — a torn or foreign envelope at the path. Recovery is deciding whether the intended
    // bytes are there, and anything it cannot read is by definition not them.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    try Data(repeating: 0x01, count: 64).write(to: envelopeURL(in: stateRoot))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: envelopeURL(in: stateRoot).path
    )

    // when
    let credential = makeCredential()
    try store.recoverUncertainCommit(
      EncryptedLLMCredentialStore.CredentialMap(providers: [.openAIChatGPT: credential]),
      key: try openKey(in: stateRoot)
    )

    // then
    #expect(try store.load(providerID: .openAIChatGPT) == credential)
  }

  @Test func recoveryThatStillCannotProveDurabilitySurfacesTheUncertainCommit() throws {
    // given — the republishing branch, with a directory fsync that keeps failing.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = makeStore(stateRoot: stateRoot, failing: .directorySync)

    // when / then — recovery may not report success on a second unproven write any more than on
    // the first.
    #expect(throws: LLMCredentialStoreError.commitUncertain) {
      try store.recoverUncertainCommit(
        EncryptedLLMCredentialStore.CredentialMap(providers: [.openAIChatGPT: makeCredential()]),
        key: try openKey(in: stateRoot)
      )
    }
  }

  @Test func recoveryThatCannotWriteAtAllSurfacesThePublicationFailure() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = makeStore(stateRoot: stateRoot, failing: .commit)

    // when / then — the republish never claimed the name, which is a different answer for the
    // caller than one that might have.
    #expect(throws: LLMCredentialStoreError.publicationFailed) {
      try store.recoverUncertainCommit(
        EncryptedLLMCredentialStore.CredentialMap(providers: [.openAIChatGPT: makeCredential()]),
        key: try openKey(in: stateRoot)
      )
    }
    #expect(SecureFilePublisher.entryExists(at: envelopeURL(in: stateRoot)) == false)
  }
}

// MARK: - Fixtures

private extension LLMCredentialStorePublicationTests {
  var syntheticProvider: LLMProviderID { LLMProviderID(rawValue: "synthetic-provider") }

  /// Every entry a sealed root with a credential map holds. Named once so a test that means to
  /// assert "nothing was stranded" cannot quietly assert "nothing exists".
  var expectedFullStateRoot: [String] {
    [SecretStatePaths.credentialEnvelopeName, SecretFile.key, SecretFile.envelope].sorted()
  }

  /// A store whose publisher fails `step` on the credential envelope only. Naming the entry is what
  /// keeps the failpoint off the runtime seal that built the fixture.
  func makeStore(
    stateRoot: URL,
    failing step: SecureFilePublisher.Failpoint.Step
  ) -> EncryptedLLMCredentialStore {
    EncryptedLLMCredentialStore(
      stateRoot: stateRoot,
      publisher: SecureFilePublisher(
        failpoint: SecureFilePublisher.Failpoint(
          step,
          on: SecretStatePaths.credentialEnvelopeName
        )
      )
    )
  }

  func openKey(in stateRoot: URL) throws -> SymmetricKey {
    try EncryptedFileSecretStore.openKey(at: SecretStatePaths(stateRoot: stateRoot).key)
  }
}
