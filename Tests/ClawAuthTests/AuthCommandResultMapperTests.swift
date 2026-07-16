import ClawCore
import Foundation
import Testing

@testable import ClawAuth

/// Text a hostile or merely broken vendor could put in a failure detail: an OSC that retitles the
/// window, a CSI that recolours it, and newlines that would spread one remote answer over the
/// owner's screen.
private let hostileDetail = "\u{1B}]0;pwned\u{7}the vendor\u{1B}[31m\n\nsaid no"

@Suite struct AuthCommandResultMapperTests {
  // MARK: - Exit Codes

  /// The codes are literals here on purpose. Comparing against the same constant the mapper reads
  /// would move both sides together and pin nothing.
  @Test(arguments: [
    (AuthCommandExit.success, Int32(0)),
    (AuthCommandExit.cancelled, Int32(130)),
    (AuthCommandExit.secretLoadFailure, Int32(11)),
    (AuthCommandExit.commandFailure, Int32(1)),
  ])
  func eachExitCarriesItsProcessCode(exit: AuthCommandExit, code: Int32) {
    // given / when / then
    #expect(exit.processExitCode == code)
  }

  /// The secret-load code is the daemon's existing one rather than a second number meaning the same
  /// thing: a supervisor already backs off on it.
  @Test func theSecretLoadExitIsTheDaemonsOwnSecretLoadCode() {
    // given / when / then
    #expect(
      AuthCommandExit.secretLoadFailure.processExitCode == ClawExitCode.secretLoadFailed.rawValue
    )
  }

  // MARK: - Failure Table

  @Test func cancellationIsItsOwnExitRatherThanAFailure() {
    // given / when
    let result = AuthCommandResultMapper.cancelled

    // then
    #expect(result.exit == .cancelled)
    #expect(result.events.isEmpty == false)
  }

  @Test(arguments: [
    SecretStoreError.missingTelegramToken,
    .keyFileInsecure("secret.key must be 32 bytes"),
    .malformedEnvelope,
    .decryptionFailed,
    .unreadable("secrets.enc"),
    .publicationFailed("seal secrets.enc"),
  ])
  func everyRuntimeSecretFailureUsesTheSecretLoadExit(error: SecretStoreError) {
    // given / when
    let result = AuthCommandResultMapper.runtimeSecretResult(for: error)

    // then
    #expect(result.exit == .secretLoadFailure)
    #expect(result.events.allSatisfy { $0.destination == .standardError })
  }

  /// A preparer that failed for a reason no typed case names is still a runtime-secret failure. It
  /// must not fall through to an ordinary command failure and let a supervisor hot-loop on it.
  @Test func anUntypedRuntimeSecretFailureStillUsesTheSecretLoadExit() {
    // given
    struct Unnamed: Error {}

    // when
    let result = AuthCommandResultMapper.runtimeSecretResult(for: Unnamed())

    // then
    #expect(result.exit == .secretLoadFailure)
  }

  /// A partial encrypted state is the one an owner can repair, and the guidance is the daemon's own.
  @Test(arguments: [
    SecretStoreError.unreadable("secrets.enc"),
    .malformedEnvelope,
    .decryptionFailed,
  ])
  func aRuntimeSecretFailureNamesTheRepairAnOwnerCanRun(error: SecretStoreError) {
    // given / when
    let result = AuthCommandResultMapper.runtimeSecretResult(for: error)

    // then
    #expect(result.events.map(\.text).joined(separator: "\n").contains("clawd secrets seal"))
  }

  @Test(arguments: [
    LLMCredentialStoreError.missingRuntimeKey,
    .insecureStorage,
    .malformedStorage,
    .unsupportedVersion,
    .oversizedStorage,
    .publicationFailed,
    .commitUncertain,
  ])
  func everyCredentialStoreFailureUsesTheSecretLoadExit(error: LLMCredentialStoreError) {
    // given / when
    let result = AuthCommandResultMapper.result(for: error)

    // then
    #expect(result.exit == .secretLoadFailure)
    #expect(result.events.allSatisfy { $0.destination == .standardError })
  }

  /// A vendor that refused, stalled, or ran out the window is an ordinary command failure. None of
  /// them is a reason to tell an owner their secret backend is broken.
  @Test(arguments: [
    ChatGPTOAuthFailure.deadlineExceeded,
    .throttled(retryAfter: .seconds(30)),
    .throttled(retryAfter: nil),
    .malformedResponse(detail: "no user code"),
    .grantRejected(detail: "the code was already spent"),
    .transport(detail: "connection reset"),
  ])
  func everyRemoteFailureIsAnOrdinaryCommandFailure(failure: ChatGPTOAuthFailure) {
    // given / when
    let result = AuthCommandResultMapper.result(for: failure)

    // then
    #expect(result.exit == .commandFailure)
    #expect(result.events.allSatisfy { $0.destination == .standardError })
  }

  @Test(arguments: [
    AuthMutationLockFailure.held,
    .unavailable(detail: "the lock file could not be opened"),
  ])
  func everyLockFailureIsAnOrdinaryCommandFailure(failure: AuthMutationLockFailure) {
    // given / when
    let result = AuthCommandResultMapper.result(for: failure)

    // then
    #expect(result.exit == .commandFailure)
  }

  @Test func aHeldLockNamesTheDaemonAsTheThingToStop() {
    // given / when
    let held = AuthCommandResultMapper.result(for: AuthMutationLockFailure.held)
    let unavailable = AuthCommandResultMapper.result(
      for: AuthMutationLockFailure.unavailable(detail: "permission denied")
    )

    // then
    let heldText = held.events.map(\.text).joined(separator: "\n").lowercased()
    #expect(heldText.contains("running"))
    #expect(heldText.contains("stop"))
    // The pairing: a lock that could not be opened at all is a different problem, and must not tell
    // an owner to stop a daemon that is not the reason.
    #expect(
      unavailable.events.map(\.text).joined(separator: "\n").lowercased().contains("stop") == false
    )
  }

  // MARK: - Redaction

  /// The mapper is the last thing between a vendor's answer and the owner's terminal. Remote text
  /// arrives sanitized by contract; sanitizing again here is what makes that a property of the thing
  /// that renders rather than a promise made upstream.
  @Test func remoteDetailReachesTheOwnerStrippedOfTerminalControl() {
    // given
    let failure = ChatGPTOAuthFailure.transport(detail: hostileDetail)

    // when
    let rendered = AuthCommandResultMapper.result(for: failure)
      .events.map(\.text).joined(separator: "\n")

    // then
    #expect(rendered.contains("\u{1B}") == false)
    #expect(rendered.contains("\u{7}") == false)
    #expect(rendered.contains("pwned") == false)
    // The pairing: the diagnostic itself survived, so the case above is not passing by rendering
    // nothing at all.
    #expect(rendered.contains("the vendor said no"))
  }

  @Test func anOversizedRemoteDetailIsBoundedBeforeItIsShown() {
    // given
    let flood = String(repeating: "A", count: ChatGPTProviderMetadata.maximumDiagnosticBytes * 4)

    // when
    let rendered = AuthCommandResultMapper.result(for: .transport(detail: flood))
      .events.map(\.text).joined(separator: "\n")

    // then
    #expect(rendered.utf8.count < flood.utf8.count)
  }
}
