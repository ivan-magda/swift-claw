import ArgumentParser
import ClawCore
import ClawGateway
import ClawSecrets
import ClawSubprocess
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

/// `secrets seal` shares the daemon's single-instance state-root lock, so a seal can never race a
/// running daemon or a concurrent seal into the key-adoption-and-rollback window a lone seal defends
/// only against itself.
@Suite struct SecretsSealCommandTests {
  @Test func sealRefusesAndLeavesStateRootUntouchedWhenTheInstanceLockIsHeld() throws {
    // given — a state root whose instance lock another clawd process already holds
    let stateRoot = try makeTemporaryRoot(prefix: "claw-seal-lock")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let paths = SecretStatePaths(stateRoot: stateRoot)
    let heldLock = try InstanceLock(path: paths.instanceLock.path)
    defer { heldLock.release() }
    let secrets = Secrets(telegramBotToken: "123:abc", llmApiKey: "sk-secret")

    // when — sealing under the already-held lock
    let thrown = #expect(throws: ExitCode.self) {
      try SecretsCommand.Seal.sealUnderInstanceLock(secrets, stateRoot: stateRoot)
    }

    // then — it fails with the already-running code and writes neither the envelope nor the key
    #expect(thrown == ExitCode(ClawExitCode.alreadyRunning.rawValue))
    #expect(FileManager.default.fileExists(atPath: paths.runtimeEnvelope.path) == false)
    #expect(FileManager.default.fileExists(atPath: paths.key.path) == false)
  }

  @Test func sealSucceedsAndDecryptsWhenTheInstanceLockIsFree() throws {
    // given — a state root with no lock held, so the seal may take it
    let stateRoot = try makeTemporaryRoot(prefix: "claw-seal-free")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let original = Secrets(telegramBotToken: "123:abc", llmApiKey: "sk-secret")

    // when
    try SecretsCommand.Seal.sealUnderInstanceLock(original, stateRoot: stateRoot)

    // then — the sealed secrets decrypt, and the released lock leaves the root free to seal again
    let loaded = try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()
    #expect(loaded == original)
    let relock = try InstanceLock(path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path)
    relock.release()
  }
}
