import Logging

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// The hard exit taken when the lane drain times out during shutdown. The terminating call is
/// injected as `@Sendable (Int32) throws -> Never` so a test can substitute a closure that records
/// the code and throws a sentinel, while production calls the C library's `_exit`, which never
/// returns. Modelling it as `-> Never` is what forces every caller to end control flow here rather
/// than fall through.
struct FatalProcessTerminator: Sendable {
  private let terminate: @Sendable (Int32) throws -> Never

  init(terminate: @escaping @Sendable (Int32) throws -> Never) {
    self.terminate = terminate
  }

  /// `_exit` terminates immediately: no `atexit` handlers, no stdio flush, no scope unwinding — the
  /// held instance-lock fd and every live dependency stay owned until the kernel reaps the process.
  static let production = FatalProcessTerminator { code in
    _exit(code)
  }

  /// Logs the runs still in flight, then terminates with a nonzero code BEFORE any scope unwinds, so
  /// no dependent resource is torn down underneath a still-running turn. The boot reconciler sweeps
  /// any run left `RUNNING` on the next start. Never returns normally.
  func fatalLaneDrainTimeout(activeRunIDs: [Int64], logger: Logger) throws -> Never {
    logger.critical(
      "lane drain timed out during shutdown; exiting without dependent-resource teardown so process termination owns the remaining work. runs still in flight: \(activeRunIDs)"
    )
    try terminate(1)
  }
}
