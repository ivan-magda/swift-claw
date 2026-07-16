import ClawCore
import Foundation

// MARK: - Seams

/// Bringing the encrypted secret backend up to something the daemon could boot from, and proving it.
///
/// Named as an operation rather than as a store because the workflow must not be able to do half of
/// it: `clawd` supplies the adapter over the shared seal, which already owns the real decrypt and
/// the inode-guarded rollback. Nothing in this module knows what a secret file is.
public protocol AuthRuntimeSecretPreparing: Sendable {
  func prepare() throws
}

/// The device flow from the first request to an approved grant, as one call. The login sequence
/// depends on the outcome, not on the poll loop that produced it.
public protocol ChatGPTDeviceAuthorizing: Sendable {
  func authorize(
    onDeviceCode: @escaping @Sendable (ChatGPTDeviceCode) async -> Void
  ) async throws -> ChatGPTAuthorizationGrant
}

// MARK: - Workflow

/// `login`, `status`, and `logout`, with no CLI in them.
///
/// The ordering inside `login` is the whole point of the type, and it is not a style: the lock comes
/// before every side effect because a daemon holding the state root must not have a credential
/// changed underneath it; the seal comes before the credential file because writing an envelope
/// beside a `secret.key` this command minted on its own would strand an environment-backed
/// installation halfway; the real decrypt comes before the first request because a login that
/// cannot prepare its secrets should cost the owner nothing, least of all a round trip; and the
/// profile UUID is minted after the exchange because a login replaces what came before it only once
/// there is something to replace it with.
public struct AuthWorkflow: Sendable {
  private let bootstrap: AuthBootstrap
  private let runtimeSecrets: any AuthRuntimeSecretPreparing
  private let coordinator: AuthMutationCoordinator
  private let makeCredentialStore: @Sendable () throws -> any LLMCredentialStore
  private let makeDeviceAuthorization: @Sendable () -> any ChatGPTDeviceAuthorizing
  private let tokenExchange: any ChatGPTOAuthExchanging
  private let catalog: any ChatGPTModelCatalogFetching
  private let terminal: any AuthTerminal
  private let profileID: @Sendable () -> UUID
  private let wallDate: @Sendable () -> Date

  public init(
    bootstrap: AuthBootstrap,
    runtimeSecrets: any AuthRuntimeSecretPreparing,
    mutationLock: any AuthMutationLocking,
    makeCredentialStore: @escaping @Sendable () throws -> any LLMCredentialStore,
    makeDeviceAuthorization: @escaping @Sendable () -> any ChatGPTDeviceAuthorizing,
    tokenExchange: any ChatGPTOAuthExchanging,
    catalog: any ChatGPTModelCatalogFetching,
    terminal: any AuthTerminal,
    profileID: @escaping @Sendable () -> UUID,
    wallDate: @escaping @Sendable () -> Date
  ) {
    self.bootstrap = bootstrap
    self.runtimeSecrets = runtimeSecrets
    coordinator = AuthMutationCoordinator(lock: mutationLock)
    self.makeCredentialStore = makeCredentialStore
    self.makeDeviceAuthorization = makeDeviceAuthorization
    self.tokenExchange = tokenExchange
    self.catalog = catalog
    self.terminal = terminal
    self.profileID = profileID
    self.wallDate = wallDate
  }

  // MARK: - Login

  public func login() async -> AuthCommandResult {
    let transcript = AuthTranscript(terminal: terminal)

    // The lock is taken before anything else happens, and that is the whole ordering: everything
    // below it seals, writes, or asks a vendor for something.
    switch coordinator.acquire() {
    case .failure(let failure):
      return await transcript.finish(AuthCommandResultMapper.result(for: failure))
    case .success(let lease):
      defer { lease.release() }
      return await transcript.finish(await runLogin(transcript))
    }
  }

  // MARK: - Status

  /// A read, and only a read. No lock, because an owner must be able to ask what the running daemon
  /// is using without fighting it for the state root; no network and no refresh, because the answer
  /// to "what is stored" is on the disk, and spending a refresh token to answer it would change the
  /// thing being reported.
  public func status() -> AuthCommandResult {
    let store: any LLMCredentialStore
    do {
      store = try makeCredentialStore()
    } catch let error as LLMCredentialStoreError {
      return AuthCommandResultMapper.result(for: error)
    } catch {
      return AuthCommandResultMapper.unexpected()
    }

    let stored: StoredOAuthCredential?
    do {
      stored = try store.load(providerID: ChatGPTProviderMetadata.providerID)
    } catch {
      return AuthCommandResultMapper.result(for: error)
    }

    var events: [AuthPresentationEvent] = [
      .output("provider: \(ChatGPTProviderMetadata.providerID.rawValue)")
    ]

    guard let stored else {
      events.append(.output("credential: none — logged out. Run `clawd auth login`."))
      return AuthCommandResult(exit: .success, events: events)
    }

    events.append(.output("credential: present"))
    events.append(
      .output(
        "expires: \(Self.expiry(stored.expiresAt)) "
          + "(\(Self.label(for: freshness(of: stored))))"
      )
    )
    if let model = ModelSelection.qualifiedChatGPTModel(in: bootstrap.configuredModel) {
      events.append(.output("model: \(model)"))
    }
    return AuthCommandResult(exit: .success, events: events)
  }

  // MARK: - Logout

  /// Local deletion, and it says so. Nothing here reaches the vendor, so an access token the owner
  /// has already been issued stays valid until it expires — an owner who believes otherwise would
  /// stop looking for a token that is still live.
  public func logout() -> AuthCommandResult {
    switch coordinator.acquire() {
    case .failure(let failure):
      return AuthCommandResultMapper.result(for: failure)
    case .success(let lease):
      defer { lease.release() }
      return runLogout()
    }
  }
}

// MARK: - The Login Sequence

private extension AuthWorkflow {
  /// Streams everything an owner should see through `transcript` as it happens, and returns only the
  /// ending. Splitting it this way is what lets the lock's `defer` in `login` be the one release.
  func runLogin(_ transcript: AuthTranscript) async -> AuthCommandResult {
    do {
      try runtimeSecrets.prepare()
    } catch {
      return AuthCommandResultMapper.runtimeSecretResult(for: error)
    }

    let grant: ChatGPTAuthorizationGrant
    do {
      grant = try await makeDeviceAuthorization().authorize { device in
        await transcript.emit(Self.deviceEvents(for: device))
      }
    } catch is CancellationError {
      return AuthCommandResultMapper.cancelled
    } catch let failure as ChatGPTOAuthFailure {
      return AuthCommandResultMapper.result(for: failure)
    } catch {
      return AuthCommandResultMapper.unexpected()
    }

    let pair: ChatGPTTokenPair
    do {
      pair = try await tokenExchange.exchange(
        grant: grant,
        timeout: ChatGPTProviderMetadata.requestTimeout
      )
    } catch is CancellationError {
      return AuthCommandResultMapper.cancelled
    } catch let failure as ChatGPTOAuthFailure {
      return AuthCommandResultMapper.result(for: failure)
    } catch {
      return AuthCommandResultMapper.unexpected()
    }

    // A pair with no refresh token cannot be stored into a refresh loop: the daemon would spend the
    // access token and then have no way to renew it. Refusing it here costs the owner only this
    // login; storing it would cost them the one they already had.
    guard let refreshToken = pair.refreshToken else {
      return AuthCommandResultMapper.result(
        for: .malformedResponse(detail: "the exchange returned no refresh token")
      )
    }

    do {
      try makeCredentialStore().save(
        StoredOAuthCredential(
          profileID: profileID(),
          accessToken: pair.accessToken,
          refreshToken: refreshToken,
          expiresAt: pair.expiresAt
        ),
        providerID: ChatGPTProviderMetadata.providerID
      )
    } catch let error as LLMCredentialStoreError {
      return AuthCommandResultMapper.result(for: error)
    } catch {
      return AuthCommandResultMapper.unexpected()
    }

    await transcript.emit([
      .output("Logged in to \(ChatGPTProviderMetadata.providerID.rawValue).")
    ])
    await selectModel(pair: pair, transcript: transcript)
    return AuthCommandResult(exit: .success, events: [])
  }

  /// The owner has a credential by the time this runs, so nothing it can fail at is a login failure.
  /// Every unhappy path ends the same way: say so, and print the assignment to set by hand.
  func selectModel(pair: ChatGPTTokenPair, transcript: AuthTranscript) async {
    let models: [ChatGPTCatalogModel]
    do {
      models = try await catalog.fetch(
        authorization: ChatGPTProviderMetadata.authorization(
          accessToken: pair.accessToken,
          generation: .zero
        )
      )
    } catch let failure as ChatGPTCatalogFailure {
      await transcript.emit(Self.manualFormEvents(because: Self.describe(failure)))
      return
    } catch {
      await transcript.emit(Self.manualFormEvents(because: "the model list could not be read"))
      return
    }

    guard let choice = await chooseModel(from: models, transcript: transcript) else {
      await transcript.emit(
        Self.manualFormEvents(because: "the provider offered no eligible models")
      )
      return
    }

    await transcript.emit(Self.assignmentEvents(for: choice))
  }

  func chooseModel(
    from models: [ChatGPTCatalogModel],
    transcript: AuthTranscript
  ) async -> ChatGPTModelChoice? {
    let configuredSuffix = ModelSelection.configuredChatGPTSuffix(in: bootstrap.configuredModel)

    // The default is computed by the same pure selector the prompt uses, with the terminal denied.
    // That is what makes the choice an unattended run takes provably the one a terminal would have
    // offered rather than a second rule that happens to agree today.
    guard
      case .chose(let fallback) = ChatGPTModelPicker.select(
        catalog: models,
        configuredSuffix: configuredSuffix,
        isInteractive: false,
        chosenIndex: nil
      )
    else {
      return nil
    }

    guard terminal.isInteractive else {
      return fallback
    }

    await transcript.emit(Self.catalogEvents(for: models, default: fallback))

    for _ in 1...ModelSelection.maximumSelectionAttempts {
      guard let typed = await readAnswer(), !typed.isEmpty else {
        // End of input, or a bare return: both mean "the one you already offered".
        return fallback
      }
      guard let index = Int(typed) else {
        await transcript.emit([.error("That is not a number. Enter a row number, or press return.")]
        )
        continue
      }
      switch ChatGPTModelPicker.select(
        catalog: models,
        configuredSuffix: configuredSuffix,
        isInteractive: true,
        chosenIndex: index
      ) {
      case .chose(let choice):
        return choice
      case .indexOutOfRange:
        await transcript.emit([
          .error("There is no row \(index). Enter a number from 1 to \(models.count).")
        ])
      case .noEligibleModels:
        return nil
      }
    }

    return fallback
  }

  /// A failed read is end of input. The credential is already stored by the time anyone is prompted,
  /// so an owner who closes the pipe gets the default rather than a failed login.
  func readAnswer() async -> String? {
    guard let line = try? await terminal.readLine() else {
      return nil
    }
    return line.trimmingCharacters(in: .whitespaces)
  }
}

// MARK: - The Logout Sequence

private extension AuthWorkflow {
  func runLogout() -> AuthCommandResult {
    let store: any LLMCredentialStore
    do {
      store = try makeCredentialStore()
    } catch let error as LLMCredentialStoreError {
      return AuthCommandResultMapper.result(for: error)
    } catch {
      return AuthCommandResultMapper.unexpected()
    }

    // Asked before it is deleted, so an absent record is answered rather than repaired: `delete`
    // alone would demand a runtime key this state root may never have had.
    do {
      guard try store.load(providerID: ChatGPTProviderMetadata.providerID) != nil else {
        return AuthCommandResult(
          exit: .success,
          events: [
            .output(
              "No stored \(ChatGPTProviderMetadata.providerID.rawValue) credential — "
                + "already logged out."
            )
          ]
        )
      }
      try store.delete(providerID: ChatGPTProviderMetadata.providerID)
    } catch {
      return AuthCommandResultMapper.result(for: error)
    }

    return AuthCommandResult(
      exit: .success,
      events: [
        .output("Removed the stored \(ChatGPTProviderMetadata.providerID.rawValue) credential."),
        .output(
          """
          This is a local deletion, not a server-side revocation: an access token already issued \
          may stay valid until it expires.
          """
        ),
      ]
    )
  }
}

// MARK: - Wording

private extension AuthWorkflow {
  /// UTC and locale-free: an expiry an owner reads has to mean the same instant as the one the
  /// vendor issued, whatever the host's region is set to.
  static func expiry(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  /// Read through the one classifier the runtime credential source and doctor also read through. A
  /// second rule here would let an owner be told a token is fresh while the source about to spend it
  /// decides otherwise.
  func freshness(of credential: StoredOAuthCredential) -> ChatGPTCredentialFreshness {
    ChatGPTCredentialFreshness.classify(expiresAt: credential.expiresAt, now: wallDate())
  }

  static func label(for freshness: ChatGPTCredentialFreshness) -> String {
    switch freshness {
    case .fresh:
      return "fresh"
    case .expiring:
      return "expiring"
    case .expired:
      return "expired"
    }
  }

  /// The user code, the fixed URL, and the window — and nothing else. The device-auth ID is a bearer
  /// of the pending authorization: anyone holding it can claim the grant the owner is about to
  /// approve, so it belongs on the wire and nowhere an owner or a log can see it.
  static func deviceEvents(for device: ChatGPTDeviceCode) -> [AuthPresentationEvent] {
    let minutes = ChatGPTProviderMetadata.maximumLoginWait.components.seconds / 60
    return [
      .output("Open \(ChatGPTProviderMetadata.verificationURL) and enter this code:"),
      .output("    \(device.userCode)"),
      .output("Waiting for approval. This code expires in \(minutes) minutes."),
    ]
  }

  static func catalogEvents(
    for models: [ChatGPTCatalogModel],
    default fallback: ChatGPTModelChoice
  ) -> [AuthPresentationEvent] {
    var events: [AuthPresentationEvent] = [.output("Available models:")]
    for (offset, model) in models.enumerated() {
      events.append(.output("  \(offset + 1). \(model.slug)"))
    }
    events.append(.output("Enter a number, or press return for \(fallback.slug):"))
    return events
  }

  static func assignmentEvents(for choice: ChatGPTModelChoice) -> [AuthPresentationEvent] {
    [
      .output(Self.explain(choice.origin)),
      .output("Set this in your environment:"),
      .output("    \(choice.assignment)"),
    ]
  }

  static func explain(_ origin: ChatGPTModelChoiceOrigin) -> String {
    switch origin {
    case .configuredDefault:
      return "Keeping the model you already had configured, which the provider still offers."
    case .firstReturnedDefault:
      return "Choosing the first model the provider returned."
    case .owner:
      return "Choosing the model you picked."
    }
  }

  static func manualFormEvents(because reason: String) -> [AuthPresentationEvent] {
    [
      .output("Logged in, but \(reason)."),
      .output("Set your model by hand:"),
      .output("    \(ModelSelection.manualAssignmentForm)"),
    ]
  }

  static func describe(_ failure: ChatGPTCatalogFailure) -> String {
    switch failure {
    case .unavailable(let detail):
      return "the model list could not be read — "
        + ChatGPTWireValues.safeRemoteDiagnostic(
          detail,
          redacting: [],
          maxBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
        )
    }
  }
}

// MARK: - Transcript

/// Login's output, streamed as it happens.
///
/// Streaming is what makes the flow usable at all: an owner cannot approve a code they have not been
/// shown, and a transcript printed after the poll loop would be a code for a window that has closed.
/// What this type adds over writing to the terminal directly is the ending — `finish` presents a
/// result's events and hands back the exit alone, which is what keeps login's promise that nothing
/// in `events` has been shown yet. A login that also returned what it had already printed would
/// leave every renderer one `for` loop away from showing the owner each line twice.
private struct AuthTranscript: Sendable {
  private let terminal: any AuthTerminal

  init(terminal: any AuthTerminal) {
    self.terminal = terminal
  }

  func emit(_ events: [AuthPresentationEvent]) async {
    for event in events {
      await terminal.write(event)
    }
  }

  func finish(_ result: AuthCommandResult) async -> AuthCommandResult {
    await emit(result.events)
    return AuthCommandResult(exit: result.exit, events: [])
  }
}
