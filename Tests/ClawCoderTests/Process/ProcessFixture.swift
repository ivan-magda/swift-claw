import ClawCore
import ClawTestSupport
import Foundation
import Synchronization

@testable import ClawCoder

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum FixtureFailure: Error { case rejected }

final class ProcessFixture: Sendable {
  let ready = AsyncGate()
  private let state = Mutex((receipt: CoderProcessReceipt?.none, stoppedAfterReap: false))
  private let capture = FixtureCapture()

  var launchedPID: Int32? {
    state.withLock { state in
      state.receipt?.pid
    }
  }
  var receipt: CoderProcessReceipt? {
    state.withLock { state in
      state.receipt
    }
  }
  var stoppedAfterReap: Bool {
    state.withLock { state in
      state.stoppedAfterReap
    }
  }
  var pids: [Int32] { get async { await capture.pids } }
  var text: String { get async { await capture.text } }

  func command(arguments: [String] = [], timeout: Duration = .seconds(10)) -> CoderCommand {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/process-group.sh").path
    return CoderCommand(
      executable: "/bin/sh",
      arguments: arguments.isEmpty ? [fixture] : arguments,
      environment: ["PATH": "/usr/bin:/bin"],
      workingDirectory: "/tmp",
      input: "",
      phase: .codex,
      timeout: timeout
    )
  }

  func record(_ event: CoderProcessEvent) async throws {
    switch event {
    case .didLaunch(let receipt):
      state.withLock { state in
        state.receipt = receipt
      }
    case .stopped:
      state.withLock {
        $0.stoppedAfterReap =
          $0.receipt?.pid.map { pid in
            kill(pid, 0) == -1 && errno == ESRCH
          } ?? false
      }
    default: break
    }
  }

  func output(_ data: Data) async {
    await capture.append(data)
    if await capture.pids.count >= 2 { ready.open() }
  }

  func cleanup() {
    if let pid = launchedPID { _ = kill(-pid, SIGKILL) }
    ready.open()
  }

  func waitForExit(_ pid: Int32) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while isLive(pid), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return !isLive(pid)
  }

  func isLive(_ pid: Int32) -> Bool {
    #if canImport(Darwin)
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
        return false
      }
      return info.pbi_status != SZOMB
    #else
      guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
        let end = stat.lastIndex(of: ")")
      else {
        return false
      }
      return stat[stat.index(after: end)...].split(separator: " ").first != "Z"
    #endif
  }
}

private actor FixtureCapture {
  var text = ""
  var pids: [Int32] {
    text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().compactMap {
      Int32($0)
    }
  }

  func append(_ data: Data) { text += String(bytes: data, encoding: .utf8) ?? "" }
}
