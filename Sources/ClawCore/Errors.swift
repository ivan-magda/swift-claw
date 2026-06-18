/// Distinct, non-zero process exit codes so a deterministic startup failure backs off
/// under the supervisor instead of hot-looping.
public enum ClawExitCode: Int32, Sendable {
  case configInvalid = 10
  case secretLoadFailed = 11
  case alreadyRunning = 12
  case storeError = 13
}

public enum ConfigError: Error, Sendable, Equatable {
  case missingBotToken
  case invalidAllowlist(String)
  case unwritableStateRoot(String)

  public var exitCode: Int32 {
    switch self {
    case .missingBotToken: ClawExitCode.secretLoadFailed.rawValue
    case .invalidAllowlist: ClawExitCode.configInvalid.rawValue
    case .unwritableStateRoot: ClawExitCode.configInvalid.rawValue
    }
  }
}

/// `conflict409` and `floodControl` are first-class so the poller can react distinctly
/// (loud-and-back-off vs. honor retry-after).
public enum TelegramError: Error, Sendable, Equatable {
  case conflict409(description: String)
  case floodControl(retryAfter: Int)
  case apiError(code: Int, description: String)
  case transport(String)
  case decoding(String)
}

public enum StoreError: Error, Sendable, Equatable {
  case openFailed(String)
  case migrationFailed(String)
}
