import Foundation
import Testing

@testable import ClawEvaluation

extension EvaluationFilesystemSecurityTests {
  @Test func workerLauncherRejectsLinkedExecutableAndInvocationPaths() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let invocation = root.appendingPathComponent("invocation.json")
    try Data("{}".utf8).write(to: invocation)
    let executableLink = root.appendingPathComponent("worker")
    try FileManager.default.createSymbolicLink(
      at: executableLink,
      withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
    )
    let invocationLink = root.appendingPathComponent("invocation-link.json")
    try FileManager.default.createSymbolicLink(at: invocationLink, withDestinationURL: invocation)
    let launcher = EvaluationSubprocessWorkerLauncher()

    // when
    let linkedExecutable = await launcher.launch(
      kind: .attempt,
      executablePath: executableLink.path,
      invocationPath: invocation.path,
      sealedOutputKey: nil
    )
    let linkedInvocation = await launcher.launch(
      kind: .attempt,
      executablePath: "/usr/bin/true",
      invocationPath: invocationLink.path,
      sealedOutputKey: nil
    )

    // then
    #expect(
      linkedExecutable == EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    )
    #expect(
      linkedInvocation == EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    )
  }

  @Test func workerLauncherStartsVerifiedRegularPaths() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let invocation = root.appendingPathComponent("invocation.json")
    let executable = root.appendingPathComponent("worker.sh")
    let observation = root.appendingPathComponent("launcher-observation.txt")
    try Data("{}".utf8).write(to: invocation)
    let script = """
      #!/bin/sh
      IFS= read -r key
      if [ "$1" = "worker" ] && [ "$2" = "--invocation" ] && [ -f "$3" ]; then
        if [ "$4" = "--sealed-output-key-stdin" ] && [ "$key" = "sealed-key" ]; then
          printf passed > "$(dirname "$0")/launcher-observation.txt"
          exit 0
        fi
      fi
      exit 9
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    // when
    let result = await EvaluationSubprocessWorkerLauncher().launch(
      kind: .attempt,
      executablePath: executable.path,
      invocationPath: invocation.path,
      sealedOutputKey: Data("sealed-key\n".utf8)
    )

    // then
    #expect(result.termination == .completed)
    #expect(result.processID != nil)
    #expect(try Data(contentsOf: observation) == Data("passed".utf8))
  }

  @Test func workerLauncherRejectsDotTraversalBeforeNormalization() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let safe = root.appendingPathComponent("safe", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let outsideChild = outside.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: safe.appendingPathComponent("link"),
      withDestinationURL: outsideChild
    )
    let executable = outside.appendingPathComponent("worker.sh")
    let observation = outside.appendingPathComponent("unexpected-launch.txt")
    try Data("#!/bin/sh\nprintf launched > \"$(dirname \"$0\")/unexpected-launch.txt\"\n".utf8)
      .write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let invocation = outside.appendingPathComponent("invocation.json")
    try Data("{}".utf8).write(to: invocation)
    let rawExecutable = safe.appendingPathComponent("link/../worker.sh")
    let rawInvocation = safe.appendingPathComponent("link/../invocation.json")

    // when
    let result = await EvaluationSubprocessWorkerLauncher().launch(
      kind: .attempt,
      executablePath: rawExecutable.path,
      invocationPath: rawInvocation.path,
      sealedOutputKey: nil
    )

    // then
    #expect(result == EvaluationWorkerLaunchResult(termination: .rejected, processID: nil))
    #expect(FileManager.default.fileExists(atPath: observation.path) == false)
  }
}
