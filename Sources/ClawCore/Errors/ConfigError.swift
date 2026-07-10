public enum ConfigError: Error, Sendable, Equatable {
  case invalidAllowlist(String)
  case unwritableStateRoot(String)
  case missingLLMBaseURL
  case missingLLMModel
  case invalidMaxTokensField(String)
  case invalidMaxTokens(String)
  case invalidBudget(String)
  case invalidBool(key: String, value: String)
  case invalidTimezone(String)
  case invalidQuietHours(String)
  case invalidScheduling(key: String, value: String)
  case invalidApprovalExpiry(String)
  case heartbeatOwnerUnresolved(allowlistCount: Int)

  public var exitCode: Int32 {
    switch self {
    case .invalidAllowlist: ClawExitCode.configInvalid.rawValue
    case .unwritableStateRoot: ClawExitCode.configInvalid.rawValue
    case .missingLLMBaseURL: ClawExitCode.configInvalid.rawValue
    case .missingLLMModel: ClawExitCode.configInvalid.rawValue
    case .invalidMaxTokensField: ClawExitCode.configInvalid.rawValue
    case .invalidMaxTokens: ClawExitCode.configInvalid.rawValue
    case .invalidBudget: ClawExitCode.configInvalid.rawValue
    case .invalidBool: ClawExitCode.configInvalid.rawValue
    case .invalidTimezone: ClawExitCode.configInvalid.rawValue
    case .invalidQuietHours: ClawExitCode.configInvalid.rawValue
    case .invalidScheduling: ClawExitCode.configInvalid.rawValue
    case .invalidApprovalExpiry: ClawExitCode.configInvalid.rawValue
    case .heartbeatOwnerUnresolved: ClawExitCode.configInvalid.rawValue
    }
  }
}
