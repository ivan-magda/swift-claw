public enum ConfigError: Error, Sendable, Equatable {
  case invalidAllowlist(String)
  case unwritableStateRoot(String)
  case missingLLMBaseURL
  case missingLLMModel
  case invalidMaxTokensField(String)
  case invalidStructuredOutput(String)
  case emptyQualifiedModelSuffix(reference: String)
  case oversizedQualifiedModelSuffix(reference: String)
  case unsafeQualifiedModelSuffix(reference: String)
  case structuredOutputUnsupportedOnRoute(providerID: LLMProviderID, mode: StructuredOutputMode)
  case invalidMaxTokens(String)
  case invalidBudget(String)
  case invalidBool(key: String, value: String)
  case invalidTimezone(String)
  case invalidQuietHours(String)
  case invalidScheduling(key: String, value: String)
  case invalidApprovalExpiry(String)
  case invalidWebFetchExemptCIDR(String)
  case heartbeatOwnerUnresolved(allowlistCount: Int)
  case invalidExecImage(String)
  case invalidExecImageRegistry(String)
  case execImageRegistryNotAllowed(String)
  case invalidExecMemoryMiB(String)
  case invalidExecCPUs(String)
  case invalidExecTimeout(String)

  /// Every config error is a configuration-invalid failure, so one exit code covers them all.
  public var exitCode: Int32 { ClawExitCode.configInvalid.rawValue }
}
