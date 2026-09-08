import ClawCoder
import ClawCore
import ClawGateway

/// Coder facts use the existing doctor table; local probes never stand in for live task state.
enum CoderHealthRows {
  enum Key {
    static let enabled = "coder.enabled"
    static let available = "coder.available"
    static let executable = "coder.executable"
    static let path = "coder.path"
    static let githubExecutable = "coder.gh"
    static let nodeExecutable = "coder.node"
    static let version = "coder.version"
    static let configHome = "coder.config_home"
    static let profile = "coder.profile"
    static let authentication = "coder.authentication"
    static let capacity = "coder.capacity"
    static let reserved = "coder.reserved"
    static let ownership = "coder.unresolved_ownership"
    static let lastFailure = "coder.last_failure"
    static let serviceFailure = "coder.service_failure"
    static let usage = "coder.usage"
  }

  static var disabled: [DoctorReport.Check] { [row(Key.enabled, "false")] }

  static func unavailable(config: CoderConfig, error: (any Error)? = nil) -> [DoctorReport.Check] {
    let reason: String

    if let error = error as? CoderError, case .unavailable(let message) = error {
      reason = message
    } else {
      reason = "Codex executable missing or incompatible; run clawd coder setup"
    }

    return configurationRows(config) + [
      pathRow(CodexBackend.effectivePath(config: config)),
      row(Key.available, "false (\(reason))", ok: false),
      row(Key.version, "unavailable"),
      row(Key.authentication, "unverified (CLI unavailable)", ok: false),
    ]
  }

  static func rows(config: CoderConfig, setup: CoderBackendSetup) -> [DoctorReport.Check] {
    let authentication: String
    let authOK: Bool

    switch setup.authentication {
    case .authenticated:
      authentication = "local login present; runtime authorization not verified"
      authOK = true
    case .missing:
      authentication = "missing login (blocker; authenticate Codex as the daemon user)"
      authOK = false
    case .unavailable:
      authentication = "unreadable local status (blocker)"
      authOK = false
    case .profileUnverified:
      authentication = "unverified: CLI status cannot inspect selected profile authentication"
      authOK = false
    }

    var rows = [
      row(Key.enabled, "true"),
      row(
        Key.available,
        setup.permitsSubmission ? "true (compatible CLI)" : "false",
        ok: setup.permitsSubmission
      ),
      row(Key.executable, setup.executable, headline: true), row(Key.version, setup.version),
      row(Key.configHome, setup.configHome ?? "default"),
      row(Key.profile, setup.profile ?? "default"),
      row(Key.authentication, authentication, ok: authOK),
      row(Key.capacity, String(config.maxConcurrentJobs)),
      row(Key.usage, "child-reported per job; separate from conversational /cost"),
    ]

    if let path = setup.searchPath {
      rows += [
        pathRow(path),
        row(
          Key.nodeExecutable,
          setup.nodeExecutable ?? "not found (needed by npm installations)",
          headline: setup.nodeExecutable != nil
        ),
        row(
          Key.githubExecutable,
          setup.githubExecutable ?? "not found (needed for GitHub tasks)",
          headline: true
        ),
      ]
    }

    return rows
  }

  static func configuration(
    config: CoderConfig,
    live: Bool,
    resolve: @Sendable (CoderConfig) async throws -> CoderBackendSetup
  ) async -> [DoctorReport.Check] {
    guard config.enabled else {
      return disabled
    }

    guard live else {
      return configurationRows(config) + [
        row(Key.available, "unverified (offline config check)"),
        row(Key.version, "unverified (no CLI probe)"),
        row(Key.authentication, "unverified (no CLI probe)"),
      ]
    }

    do {
      return rows(config: config, setup: try await resolve(config))
    } catch {
      return unavailable(config: config, error: error)
    }
  }

  static func persisted(
    store: any CoderJobStore,
    redactor: SecretRedactor
  ) -> [DoctorReport.Check] {
    var rows: [DoctorReport.Check] = []

    do {
      let jobs = try store.reservedJobs()
      let unresolved = jobs.filter {
        $0.ownership == .unresolved || $0.ownership == .launching
      }
      rows += [
        row(Key.reserved, "\(jobs.count) (persisted reservations)"),
        row(
          Key.ownership,
          unresolved.isEmpty
            ? "none"
            : unresolved.map {
              $0.id.uuidString
            }.joined(separator: ", "),
          ok: unresolved.isEmpty
        ),
      ]
    } catch {
      rows += [unreadable(Key.reserved), unreadable(Key.ownership)]
    }

    do {
      let job = try store.lastFailedJob()
      let value =
        job.map {
          """
          \($0.id): \($0.state.rawValue); \($0.result?.failure?.message ?? "no diagnostic") \
          (most recently updated failure record)
          """
        } ?? "none"
      rows.append(row(Key.lastFailure, redactor.redact(value)))
    } catch {
      rows.append(unreadable(Key.lastFailure))
    }

    return rows
  }

  static func service(_ service: CoderService?) async -> [DoctorReport.Check] {
    guard let service else {
      return [row(Key.serviceFailure, "unavailable (live daemon observation only)")]
    }

    let failure = await service.failure

    return [
      row(
        Key.serviceFailure,
        failure == nil ? "none" : "fatal persistence/process cleanup failure",
        ok: failure == nil
      )
    ]
  }
}

// MARK: - Row Construction

private extension CoderHealthRows {
  static func pathRow(_ path: String) -> DoctorReport.Check {
    let count = path.split(separator: ":").count
    let unit = count == 1 ? "directory" : "directories"

    return row(Key.path, "\(count) \(unit)", headline: true)
  }

  static func configurationRows(_ config: CoderConfig) -> [DoctorReport.Check] {
    [
      row(Key.enabled, "true"), row(Key.executable, "\(config.executable) (configured)"),
      row(Key.configHome, config.configHome ?? "inherited CODEX_HOME or daemon HOME/.codex"),
      row(Key.profile, config.profile ?? "default"),
      row(Key.capacity, String(config.maxConcurrentJobs)),
      row(Key.usage, "child-reported per job; separate from conversational /cost"),
    ]
  }

  static func row(
    _ key: String,
    _ value: String,
    ok: Bool = true,
    headline: Bool = false
  ) -> DoctorReport.Check {
    DoctorReport.Check(
      key: key,
      value: value,
      ok: ok,
      group: .coder,
      isHeadline: headline
    )
  }

  static func unreadable(_ key: String) -> DoctorReport.Check {
    row(key, "unreadable (db read failed)", ok: false)
  }
}
