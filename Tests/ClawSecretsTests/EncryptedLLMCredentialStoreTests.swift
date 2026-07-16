import ClawCore
import ClawTestSupport
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct EncryptedLLMCredentialStoreTests {
  /// A second provider that is never the subject of a save or a delete. Every mutation test carries
  /// it so "preserves unrelated records" is proven by a record the operation had no reason to touch.
  private let synthetic = LLMProviderID(rawValue: "synthetic-provider")

  // MARK: - Round trip

  @Test func loadOnAStateRootWithoutACredentialFileIsEmptyRatherThanAnError() throws {
    // given — a root with no key and no envelope: the state before a first login.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let loaded = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(
      providerID: .openAIChatGPT
    )

    // then — an absent map is an empty map, and asking must not create one.
    #expect(loaded == nil)
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  @Test func saveThenLoadRoundTripsTheCredential() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let credential = makeCredential()

    // when
    try store.save(credential, providerID: .openAIChatGPT)

    // then
    #expect(try store.load(providerID: .openAIChatGPT) == credential)
  }

  @Test func loadOnAProviderWithNoRecordIsEmptyEvenWhenTheMapExists() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    try store.save(makeCredential(), providerID: .openAIChatGPT)

    // when / then
    #expect(try store.load(providerID: synthetic) == nil)
  }

  @Test func aReplacedRecordCarriesTheProfileIDItWasSavedWith() throws {
    // given — refresh preserves the profile; re-login mints a new one. Both arrive here as a save,
    // so the stored profile must be whatever the caller last wrote, never one the store invents.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let profileID = UUID()
    try store.save(makeCredential(profileID: profileID), providerID: .openAIChatGPT)

    // when — a refresh: new tokens under the same profile.
    let refreshed = makeCredential(
      accessToken: "rotated-access",
      refreshToken: "rotated-refresh",
      profileID: profileID
    )
    try store.save(refreshed, providerID: .openAIChatGPT)

    // then
    let loaded = try #require(try store.load(providerID: .openAIChatGPT))
    #expect(loaded == refreshed)
    #expect(loaded.profileID == profileID)
  }

  @Test func savingOneProviderPreservesAnUnrelatedProvidersRecord() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let bystander = makeCredential(accessToken: "bystander-access")
    try store.save(bystander, providerID: synthetic)

    // when
    try store.save(makeCredential(), providerID: .openAIChatGPT)

    // then — the whole map is republished on every save, so an unrelated record survives only if
    // the read-modify-write really read.
    #expect(try store.load(providerID: synthetic) == bystander)
  }

  @Test func replacingOneProvidersRecordPreservesAnUnrelatedProvidersRecord() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let bystander = makeCredential(accessToken: "bystander-access")
    try store.save(bystander, providerID: synthetic)
    try store.save(makeCredential(), providerID: .openAIChatGPT)

    // when
    let replacement = makeCredential(accessToken: "replacement-access")
    try store.save(replacement, providerID: .openAIChatGPT)

    // then
    #expect(try store.load(providerID: .openAIChatGPT) == replacement)
    #expect(try store.load(providerID: synthetic) == bystander)
  }

  @Test func deletingOneProvidersRecordPreservesAnUnrelatedProvidersRecord() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let bystander = makeCredential(accessToken: "bystander-access")
    try store.save(bystander, providerID: synthetic)
    try store.save(makeCredential(), providerID: .openAIChatGPT)

    // when
    try store.delete(providerID: .openAIChatGPT)

    // then
    #expect(try store.load(providerID: .openAIChatGPT) == nil)
    #expect(try store.load(providerID: synthetic) == bystander)
  }

  @Test func deletingTheLastRecordLeavesAValidEmptyMapAndTheRuntimeArtifacts() throws {
    // given — logout with one provider stored.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    try store.save(makeCredential(), providerID: .openAIChatGPT)

    // when
    try store.delete(providerID: .openAIChatGPT)

    // then — an empty map, still decryptable, rather than a removed or truncated file. The runtime
    // secrets the daemon boots on are not logout's business and must survive it untouched.
    #expect(try store.load(providerID: .openAIChatGPT) == nil)
    #expect(try storedMap(in: stateRoot).providers.isEmpty)
    #expect(
      try entryNames(in: stateRoot)
        == [
          SecretStatePaths.credentialEnvelopeName,
          SecretFile.key,
          SecretFile.envelope,
        ].sorted()
    )
    #expect(try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets() == runtimeSecrets)
  }

  @Test func deletingARecordThatIsAlreadyGoneIsAQuietNoOp() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    try store.save(makeCredential(), providerID: .openAIChatGPT)
    try store.delete(providerID: .openAIChatGPT)
    let settled = try Data(contentsOf: envelopeURL(in: stateRoot))

    // when
    try store.delete(providerID: .openAIChatGPT)

    // then — a delete with nothing to remove publishes nothing, so it cannot mint a fresh nonce for
    // a map that did not change.
    #expect(try Data(contentsOf: envelopeURL(in: stateRoot)) == settled)
  }

  @Test func deletingOnAStateRootWithoutACredentialFileCreatesNothing() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).delete(providerID: .openAIChatGPT)

    // then
    #expect(SecureFilePublisher.entryExists(at: envelopeURL(in: stateRoot)) == false)
  }

  // MARK: - On-disk format

  @Test func theStoredMapIsAVersionedJSONObjectKeyedByProviderID() throws {
    // given — the plaintext shape is a durable on-disk format: `LLMProviderID` conforms to
    // `CodingKeyRepresentable`, without which `Dictionary` would emit the flat alternating array
    // `["openai-chatgpt", {…}]` instead. Pinning the bytes is what stops that conformance from
    // being dropped later and silently reinterpreting a file holding the owner's only refresh token.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)

    // when
    try store.save(
      StoredOAuthCredential(
        profileID: try #require(UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")),
        accessToken: "access-a",
        refreshToken: "refresh-a",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
      ),
      providerID: .openAIChatGPT
    )
    try store.save(
      StoredOAuthCredential(
        profileID: try #require(UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000002")),
        accessToken: "access-b",
        refreshToken: "refresh-b",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
      ),
      providerID: synthetic
    )

    // then
    let plaintext = try storedPlaintext(in: stateRoot)
    #expect(
      try #require(String(bytes: plaintext, encoding: .utf8)) == Self.pinnedTwoRecordPlaintext
    )

    // … and the same shape read back through a parser that cannot be fooled by a lucky substring:
    // `providers` must be a JSON object whose keys are the provider IDs, not an array.
    let root = try #require(
      try JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    )
    #expect(root["version"] as? Int == 1)
    let providers = try #require(root["providers"] as? [String: Any])
    #expect(providers.keys.sorted() == ["openai-chatgpt", "synthetic-provider"])
    #expect(root["providers"] as? [Any] == nil)
  }

  @Test func theCredentialEnvelopeIsPublishedOwnerOnly() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )

    // then
    #expect(try permissionBits(of: envelopeURL(in: stateRoot)) == 0o600)
  }

  @Test func theCredentialEnvelopeCarriesNoPlaintextTokenProfileOrAccountMetadata() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let profileID = UUID()
    let credential = StoredOAuthCredential(
      profileID: profileID,
      accessToken: "ya29.owner@example.com.access-secret",
      refreshToken: "rt-owner@example.com.refresh-secret",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    // when
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      credential,
      providerID: .openAIChatGPT
    )
    let envelope = try Data(contentsOf: envelopeURL(in: stateRoot))

    // then — a real byte search over the ciphertext at rest: no token, no account identifier, no
    // profile UUID in either case, no provider key and no field name of the payload's own schema.
    let forbidden = [
      credential.accessToken,
      credential.refreshToken,
      "owner@example.com",
      profileID.uuidString,
      profileID.uuidString.lowercased(),
      LLMProviderID.openAIChatGPT.rawValue,
      "providers",
      "profileID",
      "accessToken",
      "refreshToken",
      "expiresAt",
    ]
    for needle in forbidden {
      #expect(envelope.range(of: Data(needle.utf8)) == nil, "found \(needle) in the ciphertext")
    }
  }

  // MARK: - Concurrency

  @Test func concurrentLoadsObserveOnlyACompleteOldOrNewCredential() async throws {
    // given — a reader takes no lock: the rename is what makes a load atomic, so a reader must
    // never catch a half-written map. Every observation is one of the two complete records.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedLLMCredentialStore(stateRoot: stateRoot)
    let older = makeCredential(accessToken: "older-access", refreshToken: "older-refresh")
    let newer = makeCredential(accessToken: "newer-access", refreshToken: "newer-refresh")
    try store.save(older, providerID: .openAIChatGPT)

    // when
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for turn in 0..<20 {
          try store.save(turn.isMultiple(of: 2) ? newer : older, providerID: .openAIChatGPT)
        }
      }
      for _ in 0..<3 {
        group.addTask {
          for _ in 0..<40 {
            let observed = try store.load(providerID: .openAIChatGPT)
            #expect(observed == older || observed == newer)
          }
        }
      }
      try await group.waitForAll()
    }
  }

  // MARK: - Key failures

  @Test func aStateRootWithACredentialFileButNoKeyReportsTheMissingKey() throws {
    // given — the credential map is sealed under the runtime key, so an envelope standing alone is
    // unopenable. It must not read as "no credential stored".
    let stateRoot = try makeTemporaryRoot(prefix: "claw-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try writeEnvelope(Data(repeating: 0x01, count: 64), in: stateRoot)

    // when / then
    #expect(throws: LLMCredentialStoreError.missingRuntimeKey) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func savingWithoutARuntimeKeyReportsTheMissingKeyAndWritesNothing() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when / then — login seals the runtime secrets first; a store that minted a key of its own
    // would strand an environment-backed installation half encrypted.
    #expect(throws: LLMCredentialStoreError.missingRuntimeKey) {
      try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
        makeCredential(),
        providerID: .openAIChatGPT
      )
    }
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  @Test func aWorldReadableRuntimeKeyIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )
    try setPermissions(0o644, on: stateRoot.appendingPathComponent(SecretFile.key))

    // when / then
    #expect(throws: LLMCredentialStoreError.insecureStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  // MARK: - Envelope authentication

  @Test func aCredentialMapSealedUnderADifferentKeyIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )

    // when — the key is replaced by a well-formed but unrelated one.
    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try Data(repeating: 0x7E, count: EncryptedFileSecretStore.keyByteCount).write(to: keyURL)
    try setPermissions(0o600, on: keyURL)

    // then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func theRuntimeEnvelopeAtTheCredentialPathFailsAuthenticationNotDecoding() throws {
    // given — both envelopes are sealed under the same key, so only the associated data can keep
    // them apart. Swapping them is what an owner does by accident and an attacker does on purpose.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let runtime = try Data(contentsOf: stateRoot.appendingPathComponent(SecretFile.envelope))
    try writeEnvelope(runtime, in: stateRoot)

    // when / then — asserted at the envelope seam, because the public one cannot tell the two
    // failures apart: the runtime plaintext is not a credential map, so a store that DID decrypt it
    // would refuse it a moment later at the decoder and report the very same closed error. Only
    // here does sharing the associated data change the observable outcome — it would hand back the
    // runtime secrets' plaintext instead of throwing.
    let key = try EncryptedFileSecretStore.openKey(
      at: SecretStatePaths(stateRoot: stateRoot).key
    )
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore.openEnvelope(runtime, key: key)
    }

    // … and the owner-facing seam still refuses it, whichever step did the refusing.
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func theCredentialEnvelopeMovedToTheRuntimePathFailsAuthentication() throws {
    // given — the same swap in the other direction, proving the distinction is symmetric rather
    // than an accident of one reader being stricter than the other.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )

    // when
    let credentials = try Data(contentsOf: envelopeURL(in: stateRoot))
    try credentials.write(to: stateRoot.appendingPathComponent(SecretFile.envelope))

    // then
    #expect(throws: SecretStoreError.decryptionFailed) {
      _ = try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()
    }
  }

  @Test func anUnsupportedEnvelopeVersionIsRefusedBeforeDecryption() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )

    // when
    var bytes = try Data(contentsOf: envelopeURL(in: stateRoot))
    bytes[0] = 0x99
    try writeEnvelope(bytes, in: stateRoot)

    // then — an unknown version is a dispatch failure, not a tampering one: it is named apart so a
    // future format can tell an owner to upgrade rather than to log in again.
    #expect(throws: LLMCredentialStoreError.unsupportedVersion) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func aTamperedCiphertextIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )

    // when
    var bytes = try Data(contentsOf: envelopeURL(in: stateRoot))
    bytes[bytes.count - 1] ^= 0xFF
    try writeEnvelope(bytes, in: stateRoot)

    // then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func aTruncatedEnvelopeIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )

    // when — the tail carries the GCM tag, so a torn file loses its authentication first.
    let bytes = try Data(contentsOf: envelopeURL(in: stateRoot))
    try writeEnvelope(bytes.dropLast(8), in: stateRoot)

    // then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func anEmptyEnvelopeIsRefusedRatherThanReadAsAnEmptyMap() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try writeEnvelope(Data(), in: stateRoot)

    // then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func anUnsupportedPlaintextMapVersionIsRefused() throws {
    // given — a genuinely authentic envelope under the right key and the right associated data,
    // carrying a map version this build does not know. Authentication is not the thing under test.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try sealPlaintext(Data(#"{"version":2,"providers":{}}"#.utf8), in: stateRoot)

    // when / then
    #expect(throws: LLMCredentialStoreError.unsupportedVersion) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func anAuthenticEnvelopeCarryingMalformedPlaintextIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try sealPlaintext(Data("not-json-at-all".utf8), in: stateRoot)

    // when / then — the decoder's own error names the bytes it choked on, so none of it may reach
    // the seam.
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func anAuthenticEnvelopeWithoutAMapVersionIsRefused() throws {
    // given — the version is not optional with a default: a map that never carried one is a map
    // this build cannot vouch for.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try sealPlaintext(Data(#"{"providers":{}}"#.utf8), in: stateRoot)

    // when / then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  // MARK: - Bounds and metadata

  @Test func anEnvelopeLargerThanTheCapIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let oversized = EncryptedLLMCredentialStore.maximumEnvelopeByteCount + 1

    // when
    try writeEnvelope(Data(repeating: 0x01, count: oversized), in: stateRoot)

    // then
    #expect(throws: LLMCredentialStoreError.oversizedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func anEnvelopeExactlyAtTheCapIsRefusedOnItsContentRatherThanItsSize() throws {
    // given — the boundary is inclusive. Reaching the tag check at exactly the cap is what proves
    // the oversize refusal above came from the size rule and not from the junk bytes.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try writeEnvelope(
      Data([1]) + Data(repeating: 0x01, count: 256 * 1024 - 1),
      in: stateRoot
    )

    // then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func theCredentialReadPolicyCapsTheEnvelopeAndDemandsOwnerOnlyMode() throws {
    // given — the policy the store hands the protocol. `read` proves these facts from `fstat`
    // before allocating a byte of payload, so the cap declared here is the cap enforced ahead of
    // the plaintext.
    let policy = EncryptedLLMCredentialStore.envelopeReadPolicy

    // when / then
    #expect(policy.maximumByteCount == 256 * 1024)
    #expect(policy.requiredPermissionBits == SecureFilePublisher.ownerOnlyPermissions)
  }

  @Test func aSymlinkAtTheCredentialPathIsRefusedWithoutFollowingIt() throws {
    // given — a link aimed at a file the daemon can read. Following it would let anyone who can
    // write the state root choose what the store decrypts.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let elsewhere = stateRoot.appendingPathComponent("elsewhere.bin")
    try Data("victim".utf8).write(to: elsewhere)
    try setPermissions(0o600, on: elsewhere)
    try FileManager.default.createSymbolicLink(
      at: envelopeURL(in: stateRoot),
      withDestinationURL: elsewhere
    )

    // when / then — an entry stands at the path, so this is a refusal, never an absent map.
    #expect(throws: LLMCredentialStoreError.insecureStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
    #expect(try Data(contentsOf: elsewhere) == Data("victim".utf8))
  }

  @Test func aWorldReadableCredentialEnvelopeIsRefused() throws {
    // given — unlike `secrets.enc`, whose 0644 predates the publication protocol and must keep
    // opening, this file is new: nothing on any disk anywhere is allowed to be group-readable.
    let stateRoot = try makeSealedRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )
    try setPermissions(0o644, on: envelopeURL(in: stateRoot))

    // when / then
    #expect(throws: LLMCredentialStoreError.insecureStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func theCredentialReadPolicyAcceptsAnOwnerOnlyRegularFileWithinTheCap() {
    // given
    let facts = SecureFileFacts(
      device: 1,
      inode: 2,
      isRegularFile: true,
      permissionBits: 0o600,
      ownerUID: getuid(),
      byteCount: EncryptedLLMCredentialStore.maximumEnvelopeByteCount
    )

    // when / then
    #expect(throws: Never.self) {
      try SecureFilePublisher.validate(
        facts,
        name: SecretStatePaths.credentialEnvelopeName,
        policy: EncryptedLLMCredentialStore.envelopeReadPolicy,
        expectedUID: getuid()
      )
    }
  }
}

// MARK: - Pinned Plaintext

private extension EncryptedLLMCredentialStoreTests {
  /// The exact plaintext a two-record map encodes to. Written out rather than derived, so a change
  /// to the shape has to be made here on purpose: every field name, the object-keyed `providers`,
  /// the lexicographic ordering `.sortedKeys` imposes, and the version.
  static let pinnedTwoRecordPlaintext = """
    {"providers":{"openai-chatgpt":{"accessToken":"access-a","expiresAt":821692800,\
    "profileID":"A1B2C3D4-0000-4000-8000-000000000001","refreshToken":"refresh-a"},\
    "synthetic-provider":{"accessToken":"access-b","expiresAt":921692800,\
    "profileID":"A1B2C3D4-0000-4000-8000-000000000002","refreshToken":"refresh-b"}},"version":1}
    """
}

// MARK: - Disk Inspection

private extension EncryptedLLMCredentialStoreTests {
  func setPermissions(_ bits: Int, on url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: bits], ofItemAtPath: url.path)
  }

  /// Plants exact bytes at the credential path with the mode the reader demands, so a test that
  /// means to exercise the content rules is not stopped by the metadata rules first.
  func writeEnvelope(_ bytes: Data, in stateRoot: URL) throws {
    let url = envelopeURL(in: stateRoot)
    try? FileManager.default.removeItem(at: url)
    try bytes.write(to: url)
    try setPermissions(0o600, on: url)
  }

  /// Seals arbitrary plaintext under the root's real key and the store's real associated data —
  /// an envelope that authenticates, so only what is inside it is on trial.
  func sealPlaintext(_ plaintext: Data, in stateRoot: URL) throws {
    let key = try EncryptedFileSecretStore.openKey(
      at: SecretStatePaths(stateRoot: stateRoot).key
    )
    try writeEnvelope(
      try EncryptedLLMCredentialStore.sealEnvelope(plaintext, key: key),
      in: stateRoot
    )
  }

  func storedPlaintext(in stateRoot: URL) throws -> Data {
    let key = try EncryptedFileSecretStore.openKey(
      at: SecretStatePaths(stateRoot: stateRoot).key
    )
    return try EncryptedLLMCredentialStore.openEnvelope(
      try Data(contentsOf: envelopeURL(in: stateRoot)),
      key: key
    )
  }

  func storedMap(in stateRoot: URL) throws -> EncryptedLLMCredentialStore.CredentialMap {
    try EncryptedLLMCredentialStore.decode(try storedPlaintext(in: stateRoot))
  }
}
