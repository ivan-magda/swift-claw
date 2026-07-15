import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawSecrets

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

@Suite struct SecureFilePublisherTests {
  private let ownerOnly = SecureFilePublisher.ReadPolicy(
    maximumByteCount: 1024,
    requiredPermissionBits: SecureFilePublisher.ownerOnlyPermissions
  )
  private let anyMode = SecureFilePublisher.ReadPolicy(
    maximumByteCount: 1024,
    requiredPermissionBits: nil
  )

  private func permissionBits(of url: URL) throws -> UInt32 {
    var status = stat()
    #expect(lstat(url.path, &status) == 0)
    return UInt32(status.st_mode) & SecureFilePublisher.permissionBitsMask
  }

  private func entryNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  // MARK: - Publication

  @Test func publishWritesAnOwnerOnlyRegularFileWithTheExactBytes() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    let payload = Data("published-bytes".utf8)

    // when
    let outcome = try SecureFilePublisher().publish(payload, to: target)

    // then
    #expect(outcome.isCommitUncertain == false)
    #expect(try Data(contentsOf: target) == payload)
    #expect(try permissionBits(of: target) == SecureFilePublisher.ownerOnlyPermissions)
    #expect(try SecureFilePublisher.read(at: target, policy: ownerOnly) == payload)
  }

  @Test func publishLeavesNoTemporaryEntryBehindOnSuccess() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope

    // when
    _ = try SecureFilePublisher().publish(Data("bytes".utf8), to: target)

    // then — the same-directory temp name must not survive the rename.
    #expect(try entryNames(in: stateRoot) == [SecretStatePaths.credentialEnvelopeName])
  }

  @Test func publishedIdentityNamesTheInodeNowAtTheTarget() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope

    // when — the identity is captured from the temp descriptor; rename must carry that inode over.
    let outcome = try SecureFilePublisher().publish(Data("bytes".utf8), to: target)

    // then
    let onDisk = try #require(SecureFilePublisher.facts(ofEntryAt: target))
    #expect(outcome.identity == onDisk.identity)
  }

  @Test func publishReplacesAnExistingValueAtomically() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    _ = try SecureFilePublisher().publish(Data("old".utf8), to: target)

    // when
    _ = try SecureFilePublisher().publish(Data("new".utf8), to: target)

    // then
    #expect(try Data(contentsOf: target) == Data("new".utf8))
    #expect(try entryNames(in: stateRoot) == [SecretStatePaths.credentialEnvelopeName])
  }

  // MARK: - Failpoints

  @Test(
    arguments: [
      SecureFilePublisher.Failpoint.tempWrite,
      SecureFilePublisher.Failpoint.fileSync,
      SecureFilePublisher.Failpoint.rename,
    ]
  ) func everyPreRenameFailpointLeavesTheOldValueAndNoTemporaryEntry(
    failpoint: SecureFilePublisher.Failpoint
  ) throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    _ = try SecureFilePublisher().publish(Data("old".utf8), to: target)

    // when
    let failing = SecureFilePublisher(failpoint: failpoint)

    // then — nothing was renamed, so the old value is still the whole truth on disk.
    #expect(throws: SecureFileError.self) {
      _ = try failing.publish(Data("new".utf8), to: target)
    }
    #expect(try Data(contentsOf: target) == Data("old".utf8))
    #expect(try entryNames(in: stateRoot) == [SecretStatePaths.credentialEnvelopeName])
  }

  @Test func aPreRenameFailpointOnAFreshTargetCreatesNothing() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope

    // when
    let failing = SecureFilePublisher(failpoint: .rename)

    // then
    #expect(throws: SecureFileError.self) {
      _ = try failing.publish(Data("new".utf8), to: target)
    }
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  @Test func aDirectorySyncFailpointReportsCommitUncertainWithTheNewValueInPlace() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-publish")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    _ = try SecureFilePublisher().publish(Data("old".utf8), to: target)

    // when — the rename committed; only its durability is unproven.
    let outcome = try SecureFilePublisher(failpoint: .directorySync)
      .publish(Data("new".utf8), to: target)

    // then — a caller must not treat this as "nothing was written".
    #expect(outcome.isCommitUncertain)
    #expect(try Data(contentsOf: target) == Data("new".utf8))
  }

  // MARK: - Bounded, no-follow reads

  @Test func readRefusesASymlinkEvenWhenItsTargetIsWellFormed() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let real = stateRoot.appendingPathComponent("real.bin")
    _ = try SecureFilePublisher().publish(Data("bytes".utf8), to: real)
    let link = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    // when / then
    #expect(throws: SecureFileError.self) {
      _ = try SecureFilePublisher.read(at: link, policy: ownerOnly)
    }
  }

  @Test func readRefusesANonRegularEntry() throws {
    // given — a directory standing in for the envelope: open succeeds, fstat must reject it.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

    // when / then
    #expect(throws: SecureFileError.self) {
      _ = try SecureFilePublisher.read(at: target, policy: ownerOnly)
    }
  }

  @Test func readRefusesAWorldReadableEntryWhenThePolicyDemandsOwnerOnly() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    try Data("bytes".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)

    // when / then
    #expect(throws: SecureFileError.self) {
      _ = try SecureFilePublisher.read(at: target, policy: ownerOnly)
    }
  }

  @Test func readAcceptsAWorldReadableEntryWhenThePolicyDoesNotDemandOwnerOnly() throws {
    // given — Foundation's atomic write created `secrets.enc` 0644 in every installation sealed
    // before this protocol existed. That ciphertext's confidentiality rests on the mode-checked
    // key, so the runtime envelope's policy must keep opening it rather than lock the owner out.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).runtimeEnvelope
    try Data("legacy-ciphertext".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)

    // when / then
    #expect(
      try SecureFilePublisher.read(at: target, policy: anyMode) == Data("legacy-ciphertext".utf8)
    )
  }

  @Test func readRefusesAnEntryLargerThanTheCap() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    _ = try SecureFilePublisher().publish(Data(repeating: 0xAB, count: 1025), to: target)

    // when / then
    #expect(throws: SecureFileError.self) {
      _ = try SecureFilePublisher.read(at: target, policy: ownerOnly)
    }
  }

  @Test func readAcceptsAnEntryExactlyAtTheCap() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    let payload = Data(repeating: 0xAB, count: 1024)
    _ = try SecureFilePublisher().publish(payload, to: target)

    // when / then
    #expect(try SecureFilePublisher.read(at: target, policy: ownerOnly) == payload)
  }

  @Test func readRefusesAMissingEntry() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-read")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when / then
    #expect(throws: SecureFileError.self) {
      _ = try SecureFilePublisher.read(
        at: SecretStatePaths(stateRoot: stateRoot).credentialEnvelope,
        policy: ownerOnly
      )
    }
  }

  // MARK: - Metadata policy

  // Owner mismatch, file type, mode and the size cap are validated through the pure policy seam:
  // there is no portable way to chown to a foreign uid unprivileged, so a synthetic uid is the only
  // honest way to prove the rule exists.
  @Test(arguments: [
    (
      name: "non-regular", isRegular: false, perms: UInt32(0o600), owner: UInt32(0), size: 8,
      rejects: true
    ),
    (
      name: "world-readable", isRegular: true, perms: UInt32(0o644), owner: UInt32(0), size: 8,
      rejects: true
    ),
    (
      name: "group-readable", isRegular: true, perms: UInt32(0o640), owner: UInt32(0), size: 8,
      rejects: true
    ),
    (
      name: "wrong-owner", isRegular: true, perms: UInt32(0o600), owner: UInt32(1), size: 8,
      rejects: true
    ),
    (
      name: "over-cap", isRegular: true, perms: UInt32(0o600), owner: UInt32(0), size: 1025,
      rejects: true
    ),
    (
      name: "at-cap", isRegular: true, perms: UInt32(0o600), owner: UInt32(0), size: 1024,
      rejects: false
    ),
    (
      name: "well-formed", isRegular: true, perms: UInt32(0o600), owner: UInt32(0), size: 8,
      rejects: false
    ),
  ]) func ownerOnlyMetadataPolicy(
    name: String,
    isRegular: Bool,
    perms: UInt32,
    owner: UInt32,
    size: Int,
    rejects: Bool
  ) {
    // given
    let facts = SecureFileFacts(
      device: 1,
      inode: 2,
      isRegularFile: isRegular,
      permissionBits: perms,
      ownerUID: getuid() &+ owner,
      byteCount: size
    )

    // when / then
    if rejects {
      #expect(throws: SecureFileError.self) {
        try SecureFilePublisher.validate(
          facts,
          name: "probe.bin",
          policy: ownerOnly,
          expectedUID: getuid()
        )
      }
    } else {
      #expect(throws: Never.self) {
        try SecureFilePublisher.validate(
          facts,
          name: "probe.bin",
          policy: ownerOnly,
          expectedUID: getuid()
        )
      }
    }
  }

  @Test func aPolicyWithoutAModeRequirementStillRejectsAForeignOwner() {
    // given
    let facts = SecureFileFacts(
      device: 1,
      inode: 2,
      isRegularFile: true,
      permissionBits: 0o644,
      ownerUID: getuid() &+ 1,
      byteCount: 8
    )

    // when / then — relaxing the mode rule must not relax ownership.
    #expect(throws: SecureFileError.self) {
      try SecureFilePublisher.validate(
        facts,
        name: "probe.bin",
        policy: anyMode,
        expectedUID: getuid()
      )
    }
  }

  // MARK: - Identity-guarded removal

  @Test func removalDeletesTheEntryWhoseIdentityWasRecorded() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-rollback")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    let outcome = try SecureFilePublisher().publish(Data("bytes".utf8), to: target)

    // when
    let removed = SecureFilePublisher.removeCreatedEntry(outcome.identity, at: target)

    // then
    #expect(removed)
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  @Test func removalSpareAnEntryWhoseInodeWasSubstituted() throws {
    // given — the recorded entry is replaced by a different file at the same path.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-rollback")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    let outcome = try SecureFilePublisher().publish(Data("ours".utf8), to: target)
    try FileManager.default.removeItem(at: target)
    _ = try SecureFilePublisher().publish(Data("someone-elses".utf8), to: target)

    // when
    let removed = SecureFilePublisher.removeCreatedEntry(outcome.identity, at: target)

    // then — rollback may only ever unlink its own inode.
    #expect(removed == false)
    #expect(try Data(contentsOf: target) == Data("someone-elses".utf8))
  }

  @Test func removalSparesASymlinkStandingWhereTheRecordedEntryWas() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-rollback")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    let outcome = try SecureFilePublisher().publish(Data("ours".utf8), to: target)
    let elsewhere = stateRoot.appendingPathComponent("elsewhere.bin")
    try Data("victim".utf8).write(to: elsewhere)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)

    // when — no-follow metadata sees the link itself, which is not a regular file and not our inode.
    let removed = SecureFilePublisher.removeCreatedEntry(outcome.identity, at: target)

    // then
    #expect(removed == false)
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
  }

  @Test func removalSparesAPathThatIsNowEmpty() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-rollback")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let target = SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
    let outcome = try SecureFilePublisher().publish(Data("ours".utf8), to: target)
    try FileManager.default.removeItem(at: target)

    // when / then
    #expect(SecureFilePublisher.removeCreatedEntry(outcome.identity, at: target) == false)
  }
}
