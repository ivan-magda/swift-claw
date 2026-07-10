/// Distinct, non-zero process exit codes so a deterministic startup failure backs off
/// under the supervisor instead of hot-looping.
public enum ClawExitCode: Int32, Sendable {
  case configInvalid = 10
  case secretLoadFailed = 11
  case alreadyRunning = 12
  case storeError = 13
}
