import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerInvocationTests {
  @Test func semanticVersionAcceptsExactlyThreeNumericComponents() {
    // given
    let valid = ["0.0.0", "1.0.0", "12.34.56"]
    let invalid = ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "1.-2.3", "١.٢.٣"]

    // when
    let parsed = valid.compactMap(SemanticVersion.init)

    // then
    #expect(
      parsed == [SemanticVersion(0, 0, 0), SemanticVersion(1, 0, 0), SemanticVersion(12, 34, 56)]
    )
    #expect(invalid.allSatisfy { SemanticVersion($0) == nil })
  }

  @Test func semanticVersionUsesLexicographicNumericOrdering() {
    // given
    let versions = [
      SemanticVersion(2, 0, 0),
      SemanticVersion(1, 10, 0),
      SemanticVersion(1, 2, 10),
      SemanticVersion(1, 2, 3),
    ]

    // when
    let sorted = versions.sorted()

    // then
    #expect(
      sorted == [
        SemanticVersion(1, 2, 3),
        SemanticVersion(1, 2, 10),
        SemanticVersion(1, 10, 0),
        SemanticVersion(2, 0, 0),
      ]
    )
  }

  @Test func settingsKeepOnePinnedAuthority() throws {
    // given
    let image = try #require(
      PinnedImageReference.parse(
        "cgr.dev/swift-claw/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )
    )

    // when
    let settings = ExecSandboxSettings(workloadImage: image, memoryMiB: 1024, cpus: 4)

    // then
    #expect(settings.workloadImage == image)
    #expect(settings.memoryMiB == 1024)
    #expect(settings.cpus == 4)
    #expect(ExecSandboxSettings.minimumContainerVersion == SemanticVersion(1, 0, 0))
    #expect(ExecSandboxSettings.pythonInterpreter == "/usr/bin/python")
    #expect(ExecSandboxSettings.shellInterpreter == "/bin/sh")
    #expect(ExecSandboxSettings.platform == "linux/arm64")
  }

  @Test func commandResultCarriesRawPrefixesAndTypedTermination() {
    // given
    let output = CapturedCommandStream(
      bytes: Data([0x66, 0x6f, 0x6f]),
      totalBytes: 9,
      truncated: true
    )
    let command = ContainerCommand(
      arguments: ["system", "status"],
      timeout: .seconds(5),
      captureLimit: 1024,
      teardownGracePeriod: .seconds(2)
    )

    // when
    let result = ContainerCommandResult(
      termination: .exited(7),
      stdout: output,
      stderr: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
      processIdentifier: 42,
      wallClock: .milliseconds(20)
    )

    // then
    #expect(command.arguments == ["system", "status"])
    #expect(command.teardownGracePeriod == .seconds(2))
    #expect(result.termination == .exited(7))
    #expect(result.stdout == output)
    #expect(result.processIdentifier == 42)
  }

  @Test func identityUsesDeterministicLowercaseUUIDName() throws {
    // given
    let uuid = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

    // when
    let identity = ExecutionIdentity(uuid: uuid)

    // then
    #expect(identity.identifier == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    #expect(identity.name == "clawd-exec-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
  }
}
