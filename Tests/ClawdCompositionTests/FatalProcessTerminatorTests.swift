import ClawTestSupport
import Foundation
import Testing

@testable import clawd

@Suite
struct FatalProcessTerminatorTests {
  @Test
  func terminatesWithNonzeroCodeAndNeverReturnsNormally() throws {
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
      try terminator.fatalLaneDrainTimeout(activeRunIDs: [1, 2, 3], logger: TestLog.silent)
    }
    #expect(recorded.value == 1)
  }

  @Test
  func writesTheActiveRunIDsBeforeTerminating() throws {
    // given
    let capture = RecordingLogCapture()
    let terminator = FatalProcessTerminator { _ in
      throw FatalExitSentinel()
    }

    // when
    #expect(throws: FatalExitSentinel.self) {
      try terminator.fatalLaneDrainTimeout(
        activeRunIDs: [7, 42],
        logger: capture.logger()
      )
    }

    // then — the runs still in flight are reported for the operator and the boot reconciler.
    let logged = capture.entries.map(\.message).joined(separator: "\n")
    #expect(logged.contains("7"))
    #expect(logged.contains("42"))
  }
}
