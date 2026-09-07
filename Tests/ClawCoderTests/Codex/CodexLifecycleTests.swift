import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawCoder

extension CodexBackendTests {
  @Test func compatibilityRefusal() async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    let unsupportedHelp = try fixture.read("help").replacingOccurrences(
      of: "--approve-for-me",
      with: "--approve-for-me-removed"
    )
    try fixture.write("help", unsupportedHelp)
    let invocation = try await fixture.invocation()
    let backend = try fixture.backend()

    // when
    let result = await backend.run(invocation) { _ in }
    let failure = await #expect(throws: CoderError.self) { try await backend.compatibility() }

    // then
    #expect(result.state == .failed)
    #expect(result.failure?.stage == .launch)
    #expect(result.failure?.message.contains("--approve-for-me") == true)
    #expect(failure != nil)
    #expect(result.publication == .absent)
    #expect(!FileManager.default.fileExists(atPath: fixture.git.root.path + "/argv"))
  }

  @Test func missingAbsolute() async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    let config = CoderConfig(
      enabled: true,
      maxConcurrentJobs: 1,
      jobTimeoutSeconds: 30,
      executable: fixture.git.root.appendingPathComponent("missing/codex").path,
      profile: nil,
      configHome: nil
    )

    // when
    let failure = #expect(throws: CoderError.self) {
      try CodexBackend(config: config, environment: ["PATH": fixture.git.root.path])
    }

    // then
    #expect(failure != nil)
  }

  @Test(arguments: ["cancel", "timeout", "supervision"])
  func stoppedAndSupervision(mode: String) async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    try await fixture.git.git(["remote", "add", "origin", "https://github.com/owner/project"])
    try fixture.write("quiet", "")
    let request = CoderRequest(
      source: .githubRepository(url: "https://github.com/owner/project"),
      task: "Fix and publish",
      workspace: .separate,
      startRef: nil,
      deliverable: .pullRequest,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    )
    let prepared = try await CoderRequestPreparer(executionPolicyID: "fixture").prepare(request)
    let invocation = fixture.git.invocation(prepared, timeout: .seconds(10))
    let backend = try fixture.backend()
    let callback = CooperativeCallback()
    let process = ProcessFixture()
    let executionFinished = CompletionFlag()
    let finalReceiptEntered = AsyncGate()
    let releaseFinalReceipt = AsyncGate()
    defer { releaseFinalReceipt.open() }
    let operation = Task {
      defer {
        callback.entered.open()
        finalReceiptEntered.open()
      }
      let result = await backend.run(invocation) { event in
        if case .didLaunch(let receipt) = event, receipt.phase == .codex {
          let pid = try #require(receipt.pid)
          #expect(await process.waitForExit(pid))
          if mode == "supervision" {
            throw FixtureFailure.rejected
          }
          try await callback.suspend()
        }
        if case .stopped = event, mode == "timeout", callback.entered.isOpen {
          finalReceiptEntered.open()
          await releaseFinalReceipt.waitIgnoringCancellation()
        }
      }
      await executionFinished.markDone()
      return result
    }

    // when
    if mode != "supervision" {
      await callback.entered.wait()
      if mode == "cancel" {
        operation.cancel()
      }
    }
    if mode == "timeout" {
      await finalReceiptEntered.wait()
      #expect(await executionFinished.done == false)
      #expect(callback.cancelled.isOpen)
      operation.cancel()
      releaseFinalReceipt.open()
    }
    let result = await operation.value

    // then
    #expect(
      result.state == (mode == "cancel" ? .cancelled : mode == "timeout" ? .timedOut : .failed)
    )
    #expect(result.publication == .unknown(reportedURL: nil))
    if mode == "supervision" {
      #expect(result.failure?.stage == .execution)
    } else {
      #expect(callback.cancelled.isOpen)
    }
  }
}

extension CodexBackendTests {
  @Test(.enabled(if: NSUserName() != "root"))
  func protocolCleanupFailure() async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    try fixture.write("no-report", "")
    try fixture.write(
      "action",
      """
      cp "$(dirname "$0")/report" "$1"
      chmod 0500 "$(dirname "$1")"
      """
    )
    let invocation = try await fixture.invocation()

    // when
    let result = await (try fixture.backend()).run(invocation) { _ in }
    let arguments = try fixture.read("argv").split(separator: "\0").map(String.init)
    let index = try #require(arguments.firstIndex(of: "-o"))
    let directory = URL(fileURLWithPath: arguments[index + 1]).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    // then
    #expect(result.state == .failed)
    #expect(result.failure?.stage == .cleanup)
  }
}

extension CodexBackendTests {
  @Test func retainedPreparationFailure() async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    let invocation = try await fixture.invocation(fixture.git.request(mode: .separate))
    let destination = URL(fileURLWithPath: invocation.jobDirectory)
      .appendingPathComponent("repository").path

    // when
    let result = await (try fixture.backend()).run(invocation) { event in
      if case .willLaunch = event, FileManager.default.fileExists(atPath: destination) {
        throw FixtureFailure.rejected
      }
    }

    // then
    #expect(result.state == .failed)
    #expect(result.failure?.stage == .preparation)
    #expect(result.workspacePath == destination)
    #expect(!result.baselineObserved)
    #expect(result.startingCommit == nil)
  }
}
