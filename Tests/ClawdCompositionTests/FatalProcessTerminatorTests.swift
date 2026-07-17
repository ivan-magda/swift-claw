import Foundation
import Logging
import Testing

@testable import clawd

@Suite struct FatalProcessTerminatorTests {
  @Test func terminatesWithNonzeroCodeAndNeverReturnsNormally() throws {
    // given — a substitute terminator that records the code and throws instead of exiting, so the
    // test never invokes the production `_exit`.
    let recorded = ExitCodeBox()
    let terminator = FatalProcessTerminator { code in
      recorded.set(code)
      throw FatalExitSentinel()
    }

    // when / then — the sentinel escaping proves control left through `terminate()` before any
    // return; a `-> Never` function that fell through could not have thrown.
    #expect(throws: FatalExitSentinel.self) {
      try terminator.fatalLaneDrainTimeout(activeRunIDs: [1, 2, 3], logger: SilentLog.logger)
    }
    #expect(recorded.value == 1)
  }

  @Test func writesTheActiveRunIDsBeforeTerminating() throws {
    // given
    let capture = CompositionLogCapture()
    let terminator = FatalProcessTerminator { _ in
      throw FatalExitSentinel()
    }

    // when
    #expect(throws: FatalExitSentinel.self) {
      try terminator.fatalLaneDrainTimeout(
        activeRunIDs: [7, 42],
        logger: Logger(label: "test") { _ in CompositionLogHandler(capture: capture) }
      )
    }

    // then — the runs still in flight are reported for the operator and the boot reconciler.
    let logged = capture.messages.joined(separator: "\n")
    #expect(logged.contains("7"))
    #expect(logged.contains("42"))
  }
}

private enum SilentLog {
  static let logger = Logger(label: "test.silent", factory: { _ in SwiftLogNoOpLogHandler() })
}

private final class CompositionLogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(message)
  }
}

private struct CompositionLogHandler: LogHandler {
  let capture: CompositionLogCapture
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    capture.append("\(event.message)")
  }
}
