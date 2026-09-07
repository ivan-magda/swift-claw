import ClawCore
import Foundation
import Subprocess
import Testing

@testable import ClawCoder

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

enum OrphanedProcessFixture {
  static func reapLeader(of fixture: ProcessFixture) async throws -> CoderProcessReceipt {
    let command = fixture.command()
    var options = PlatformOptions()
    options.createSession = true
    let result = try await Subprocess.run(
      .path(FilePath(command.executable)),
      arguments: Arguments(command.arguments),
      environment: .custom(["PATH": "/usr/bin:/bin"]),
      platformOptions: options,
      input: .none,
      output: .sequence,
      error: .discarded
    ) { execution in
      let pid = Int32(execution.processIdentifier.value)
      let launchID = UUID()
      try await fixture.record(
        .didLaunch(
          CoderProcessReceipt(
            launchID: launchID,
            phase: .codex,
            hostBootID: "",
            pid: pid,
            pgid: pid,
            birthIdentity: nil
          )
        )
      )
      let identity = try #require(try CoderProcessIdentity.read(pid))
      let receipt = CoderProcessReceipt(
        launchID: launchID,
        phase: .codex,
        hostBootID: try CoderProcessIdentity.bootID(),
        pid: pid,
        pgid: identity.pgid,
        birthIdentity: identity.birth
      )
      try await fixture.record(.didLaunch(receipt))
      for try await buffer in execution.standardOutput {
        let data = buffer.withUnsafeBytes { bytes in
          Data(bytes)
        }
        await fixture.output(data)
        if fixture.ready.isOpen {
          try execution.send(signal: .terminate, toProcessGroup: false)
          return receipt
        }
      }
      throw FixtureFailure.rejected
    }
    return result.closureResult
  }
}
