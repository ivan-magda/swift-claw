import ClawCore
import ClawTestSupport
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct EncryptedMCPCredentialStoreTests {
  // MARK: - Round trip

  @Test func loadOnAStateRootWithoutATokenFileIsAbsentRatherThanAnError() throws {
    // given — a root with no key and no envelope: the state before a token was ever set.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let loaded = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(
      server: try makeServer()
    )

    // then — an absent map is an empty map, and asking must not create one.
    #expect(loaded == .absent)
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  @Test func saveThenLoadReturnsTheTokenForTheServerItWasSetFor() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    let server = try makeServer()

    // when
    try store.save(token: "mcp-token", for: server)

    // then
    #expect(try store.load(server: server) == .token("mcp-token"))
  }

  @Test func loadOnAServerWithNoRecordIsAbsentEvenWhenTheMapExists() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(token: "mcp-token", for: try makeServer())

    // when / then
    #expect(try store.load(server: try makeServer(name: "other")) == .absent)
  }

  @Test func savingOneServerPreservesAnUnrelatedServersToken() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    let bystander = try makeServer(name: "bystander", url: "https://bystander.example/mcp")
    try store.save(token: "bystander-token", for: bystander)

    // when — the whole map is republished on every save, so an unrelated record survives only if
    // the read-modify-write really read.
    try store.save(token: "mcp-token", for: try makeServer())

    // then
    #expect(try store.load(server: bystander) == .token("bystander-token"))
  }

  @Test func loadAllReportsEveryConfiguredServerIncludingTheOnesWithNothingStored() throws {
    // given — the boot path reads once and needs a row per server, not only per stored token.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    let configured = try makeServer()
    let untokened = try makeServer(name: "untokened", url: "https://untokened.example/mcp")
    let repointed = try makeServer(name: "repointed", url: "https://old.example/mcp")
    try store.save(token: "mcp-token", for: configured)
    try store.save(token: "repointed-token", for: repointed)

    // when
    let outcomes = try store.loadAll(
      servers: [
        configured,
        untokened,
        try makeServer(name: "repointed", url: "https://new.example/mcp"),
      ]
    )

    // then
    #expect(
      outcomes == [
        "linear": .token("mcp-token"),
        "untokened": .absent,
        "repointed": .boundToDifferentURL,
      ]
    )
  }

  @Test func storedServerNamesListsEveryRecordIncludingOnesNoLongerConfigured() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(token: "mcp-token", for: try makeServer())
    try store.save(
      token: "retired-token",
      for: try makeServer(name: "retired", url: "https://retired.example/mcp")
    )

    // when / then — a token outliving its server is exactly what an owner needs told about.
    #expect(try store.storedServerNames() == ["linear", "retired"])
  }

  // MARK: - URL binding

  @Test func aTokenSetForAnotherURLIsReportedAsBoundElsewhereRatherThanReturned() throws {
    // given — the server was re-pointed after its token was issued.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(
      token: "issued-for-old-host",
      for: try makeServer(url: "https://old.example/mcp")
    )

    // when
    let loaded = try store.load(server: try makeServer(url: "https://new.example/mcp"))

    // then — the new host must never receive a credential minted for the old one.
    #expect(loaded == .boundToDifferentURL)
    #expect(loaded.token == nil)
  }

  @Test func settingTheTokenAgainRebindsItToTheServersCurrentURL() throws {
    // given — the repair an owner is told to run after re-pointing a server.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(
      token: "issued-for-old-host",
      for: try makeServer(url: "https://old.example/mcp")
    )
    let repointed = try makeServer(url: "https://new.example/mcp")

    // when
    try store.save(token: "issued-for-new-host", for: repointed)

    // then
    #expect(try store.load(server: repointed) == .token("issued-for-new-host"))
  }

  @Test(
    arguments: [
      (setFor: "https://mcp.example/mcp", loadedFor: "HTTPS://MCP.EXAMPLE/mcp", matches: true),
      (setFor: "https://mcp.example/mcp", loadedFor: "https://mcp.example/other", matches: false),
      (
        setFor: "https://mcp.example/mcp", loadedFor: "https://mcp.example:8443/mcp", matches: false
      ),
      (setFor: "https://mcp.example/mcp", loadedFor: "http://mcp.example/mcp", matches: false),
    ]
  ) func theBindingIgnoresCaseInSchemeAndHostAndNothingElse(
    binding: (setFor: String, loadedFor: String, matches: Bool)
  ) throws {
    let (setFor, loadedFor, matches) = binding
    // given — scheme and host are case-insensitive, so a re-typed config is the same endpoint;
    // port, path, and everything after them choose which endpoint receives the token.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(token: "mcp-token", for: try makeServer(url: setFor))

    // when
    let loaded = try store.load(server: try makeServer(url: loadedFor))

    // then
    #expect(loaded == (matches ? .token("mcp-token") : .boundToDifferentURL))
  }

  // MARK: - Clearing

  @Test func deletingReportsWhetherThereWasATokenAndPreservesUnrelatedRecords() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    let bystander = try makeServer(name: "bystander", url: "https://bystander.example/mcp")
    try store.save(token: "bystander-token", for: bystander)
    try store.save(token: "mcp-token", for: try makeServer())

    // when
    let removed = try store.delete(server: "linear")
    let removedAgain = try store.delete(server: "linear")

    // then
    #expect(removed)
    #expect(removedAgain == false)
    #expect(try store.load(server: try makeServer()) == .absent)
    #expect(try store.load(server: bystander) == .token("bystander-token"))
  }

  @Test func deletingTheLastTokenLeavesAValidEmptyMapRatherThanNoFile() throws {
    // given — an absent envelope and an empty one read the same, but only one of them proves the
    // clear ran rather than something having eaten the file.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(token: "mcp-token", for: try makeServer())

    // when
    try store.delete(server: "linear")

    // then
    #expect(try storedMCPMap(in: stateRoot).servers.isEmpty)
    #expect(try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets() == runtimeSecrets)
  }

  // MARK: - On-disk protection

  @Test func theTokenEnvelopeIsPublishedOwnerOnly() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "mcp-token",
      for: try makeServer()
    )

    // then
    #expect(try permissionBits(of: mcpEnvelopeURL(in: stateRoot)) == 0o600)
  }

  @Test func theTokenEnvelopeCarriesNoPlaintextTokenServerNameOrEndpoint() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "lin_api_ownersecrettoken",
      for: try makeServer(name: "linear", url: "https://mcp.linear.app/mcp")
    )
    let envelope = try Data(contentsOf: mcpEnvelopeURL(in: stateRoot))

    // then — a real byte search over the ciphertext at rest: no token, no endpoint, no server name,
    // and no field name of the payload's own schema.
    let forbidden = [
      "lin_api_ownersecrettoken",
      "mcp.linear.app",
      "linear",
      "servers",
      "token",
      "urlFingerprint",
    ]
    for needle in forbidden {
      #expect(envelope.range(of: Data(needle.utf8)) == nil, "found \(needle) in the ciphertext")
    }
  }

  @Test func aWorldReadableTokenEnvelopeIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(token: "mcp-token", for: try makeServer())
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: mcpEnvelopeURL(in: stateRoot).path
    )

    // when / then
    #expect(throws: CredentialStoreError.insecureStorage) {
      _ = try store.load(server: try makeServer())
    }
  }

  @Test func theTokenReadPolicyCapsTheEnvelopeAndDemandsOwnerOnlyMode() {
    // given — the policy the store hands the protocol, proven from `fstat` before a byte of payload
    // is allocated.
    let policy = EncryptedMCPCredentialStore.envelopeReadPolicy

    // when / then
    #expect(policy.maximumByteCount == 256 * 1024)
    #expect(policy.requiredPermissionBits == SecureFilePublisher.ownerOnlyPermissions)
  }

  @Test func aTokenMapOnAStateRootWithoutAKeyReportsTheMissingKey() throws {
    // given — the map is sealed under the runtime key, so an envelope standing alone is unopenable.
    // It must not read as "no token stored".
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try writeMCPEnvelope(Data(repeating: 0x01, count: 64), in: stateRoot)

    // when / then
    #expect(throws: CredentialStoreError.missingRuntimeKey) {
      _ = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
    }
  }

  // MARK: - Envelope authentication

  @Test func theProviderCredentialMapAtTheTokenPathFailsAuthentication() throws {
    // given — all three envelopes are sealed under the same key, so only the associated data keeps
    // them apart. Swapping them is what an owner does by accident and an attacker does on purpose.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedLLMCredentialStore(stateRoot: stateRoot).save(
      makeCredential(),
      providerID: .openAIChatGPT
    )
    let providerEnvelope = try Data(contentsOf: envelopeURL(in: stateRoot))

    // when
    try writeMCPEnvelope(providerEnvelope, in: stateRoot)

    // then — asserted at the envelope seam as well as the owner-facing one: only here does sharing
    // the associated data change the observable outcome, by handing back the provider map's
    // plaintext instead of throwing.
    let key = try EncryptedFileSecretStore.openKey(
      at: SecretStatePaths(stateRoot: stateRoot).key
    )
    #expect(throws: CredentialStoreError.malformedStorage) {
      _ = try EncryptedMCPCredentialStore.openEnvelope(providerEnvelope, key: key)
    }
    #expect(throws: CredentialStoreError.malformedStorage) {
      _ = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
    }
  }

  @Test func theTokenMapMovedToTheProviderCredentialPathFailsAuthentication() throws {
    // given — the same swap in the other direction, proving the distinction is symmetric rather
    // than an accident of one reader being stricter than the other.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "mcp-token",
      for: try makeServer()
    )

    // when
    let tokens = try Data(contentsOf: mcpEnvelopeURL(in: stateRoot))
    try tokens.write(to: envelopeURL(in: stateRoot))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: envelopeURL(in: stateRoot).path
    )

    // then
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try EncryptedLLMCredentialStore(stateRoot: stateRoot).load(providerID: .openAIChatGPT)
    }
  }

  @Test func aTamperedTokenEnvelopeIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "mcp-token",
      for: try makeServer()
    )

    // when
    var bytes = try Data(contentsOf: mcpEnvelopeURL(in: stateRoot))
    bytes[bytes.count - 1] ^= 0xFF
    try writeMCPEnvelope(bytes, in: stateRoot)

    // then
    #expect(throws: CredentialStoreError.malformedStorage) {
      _ = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
    }
  }

  @Test func anUnsupportedEnvelopeVersionIsRefusedBeforeDecryption() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "mcp-token",
      for: try makeServer()
    )

    // when
    var bytes = try Data(contentsOf: mcpEnvelopeURL(in: stateRoot))
    bytes[0] = 0x99
    try writeMCPEnvelope(bytes, in: stateRoot)

    // then — an unknown version is a dispatch failure, not a tampering one: it keeps its own remedy.
    #expect(throws: CredentialStoreError.unsupportedVersion) {
      _ = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
    }
  }

  @Test func anUnsupportedPlaintextMapVersionIsRefused() throws {
    // given — a genuinely authentic envelope under the right key and the right associated data,
    // carrying a map version this build does not know.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try sealMCPPlaintext(Data(#"{"version":2,"servers":{}}"#.utf8), in: stateRoot)

    // when / then
    #expect(throws: CredentialStoreError.unsupportedVersion) {
      _ = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
    }
  }

  @Test func anEnvelopeLargerThanTheCapIsRefused() throws {
    // given
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    try writeMCPEnvelope(
      Data(repeating: 0x01, count: EncryptedMCPCredentialStore.maximumEnvelopeByteCount + 1),
      in: stateRoot
    )

    // then
    #expect(throws: CredentialStoreError.oversizedStorage) {
      _ = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
    }
  }

  @Test func aFailedPublicationLeavesThePreviousTokenWhole() throws {
    // given — the same crash-safe publication the provider map rides, proven to be wired up here
    // too: a failure before the commit must leave a usable token behind.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let server = try makeServer()
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    try store.save(token: "incumbent-token", for: server)
    let settled = try Data(contentsOf: mcpEnvelopeURL(in: stateRoot))

    // when
    let failing = EncryptedMCPCredentialStore(
      stateRoot: stateRoot,
      publisher: SecureFilePublisher(
        failpoint: SecureFilePublisher.Failpoint(
          .commit,
          on: SecretStatePaths.mcpCredentialEnvelopeName
        )
      )
    )

    // then — `.publicationFailed`, not `.commitUncertain`: nothing claimed the name, so the owner
    // still has the token they had.
    #expect(throws: CredentialStoreError.publicationFailed) {
      try failing.save(token: "doomed-token", for: server)
    }
    #expect(try Data(contentsOf: mcpEnvelopeURL(in: stateRoot)) == settled)
    #expect(try store.load(server: server) == .token("incumbent-token"))
  }

  // MARK: - Concurrency

  @Test func concurrentSavesForDifferentServersAllSurvive() async throws {
    // given — every save republishes the whole map, so two interleaved read-modify-write cycles
    // would drop one another's record. The store's lock is what stops that.
    let stateRoot = try makeSealedRoot(prefix: "claw-mcp-credentials")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    let servers = try (0..<8).map { index in
      try makeServer(name: "server\(index)", url: "https://server\(index).example/mcp")
    }

    // when
    await withTaskGroup(of: Void.self) { group in
      for server in servers {
        group.addTask {
          try? store.save(token: "token-for-\(server.name)", for: server)
        }
      }
    }

    // then
    for server in servers {
      #expect(try store.load(server: server) == .token("token-for-\(server.name)"))
    }
  }
}

// MARK: - Fixtures

private extension EncryptedMCPCredentialStoreTests {
  func makeServer(
    name: String = "linear",
    url: String = "https://mcp.example/mcp"
  ) throws -> MCPServerConfig {
    try MCPServerConfig(name: name, url: url)
  }
}

// MARK: - Disk Inspection

private extension EncryptedMCPCredentialStoreTests {
  /// Plants exact bytes at the token path with the mode the reader demands, so a test that means to
  /// exercise the content rules is not stopped by the metadata rules first.
  func writeMCPEnvelope(_ bytes: Data, in stateRoot: URL) throws {
    let url = mcpEnvelopeURL(in: stateRoot)
    try? FileManager.default.removeItem(at: url)
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// Seals arbitrary plaintext under the root's real key and the store's real associated data — an
  /// envelope that authenticates, so only what is inside it is on trial.
  func sealMCPPlaintext(_ plaintext: Data, in stateRoot: URL) throws {
    let key = try EncryptedFileSecretStore.openKey(
      at: SecretStatePaths(stateRoot: stateRoot).key
    )
    try writeMCPEnvelope(
      try EncryptedMCPCredentialStore.sealEnvelope(plaintext, key: key),
      in: stateRoot
    )
  }

  func storedMCPMap(in stateRoot: URL) throws -> EncryptedMCPCredentialStore.CredentialMap {
    let key = try EncryptedFileSecretStore.openKey(
      at: SecretStatePaths(stateRoot: stateRoot).key
    )
    return try EncryptedMCPCredentialStore.decode(
      try EncryptedMCPCredentialStore.openEnvelope(
        try Data(contentsOf: mcpEnvelopeURL(in: stateRoot)),
        key: key
      )
    )
  }
}
