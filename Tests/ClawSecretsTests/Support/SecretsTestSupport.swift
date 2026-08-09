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

// MARK: - Fixtures

/// The runtime secrets a login seals: a Telegram token and no LLM key (the ChatGPT route needs
/// none). One notion of the sealed runtime fixture for every suite in the target.
let runtimeSecrets = Secrets(telegramBotToken: "123:runtime", llmApiKey: nil)

/// A state root as login leaves it: the runtime secrets sealed, so `secret.key` exists and the
/// credential store has something to seal under.
func makeSealedRoot(prefix: String = "claw-credentials") throws -> URL {
  let stateRoot = try makeTemporaryRoot(prefix: prefix)
  try EncryptedFileSecretStore.seal(runtimeSecrets, stateRoot: stateRoot)
  return stateRoot
}

/// A stored credential with every field defaulted, so a test names only the fields its assertion
/// turns on.
func makeCredential(
  accessToken: String = "access-token",
  refreshToken: String = "refresh-token",
  profileID: UUID = UUID(),
  expiresAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> StoredOAuthCredential {
  StoredOAuthCredential(
    profileID: profileID,
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt
  )
}

// MARK: - Disk inspection

func envelopeURL(in stateRoot: URL) -> URL {
  SecretStatePaths(stateRoot: stateRoot).credentialEnvelope
}

func mcpEnvelopeURL(in stateRoot: URL) -> URL {
  SecretStatePaths(stateRoot: stateRoot).mcpCredentialEnvelope
}

/// The publisher-relevant permission bits `url` carries on disk, read through `lstat` so a symlink
/// is inspected rather than whatever it points at.
func permissionBits(of url: URL) throws -> UInt32 {
  var status = stat()
  #expect(lstat(url.path, &status) == 0)
  return UInt32(status.st_mode) & SecureFilePublisher.permissionBitsMask
}
