import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

@Suite struct EvaluationFilesystemSecurityTests {
  @Test func privateDirectoryPreparationRejectsALinkBeforeItCanChangeTheTarget() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("outside", isDirectory: true)
    let link = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(link.lastPathComponent)
    ) {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: link)
    }

    // then
    #expect(error != nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
  }

  @Test func privateDirectoryPreparationRejectsDotTraversalBeforeNormalization() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let safe = root.appendingPathComponent("safe", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let outsideChild = outside.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(
      at: safe.appendingPathComponent("link"),
      withDestinationURL: outsideChild
    )
    let raw = URL(fileURLWithPath: safe.appendingPathComponent("link/..").path)

    // when
    let error = #expect(throws: EvaluationPathSecurityError.dotPathComponent("..")) {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: raw)
    }

    // then
    #expect(error != nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: outside.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
  }

  @Test func privateDirectoryPreparationAcceptsTheTrustedSystemTemporaryRoot() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "claw-evaluation-path")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("private", isDirectory: true)

    // when
    try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)

    // then
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
  }

  @Test func restartLockProbeRejectsALinkedStateRootBeforeCreatingALock() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let linkedState = root.appendingPathComponent("linked-state", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedState, withDestinationURL: outside)

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(linkedState.lastPathComponent)
    ) {
      _ = try EvaluationWorkerLifecycle.proveProductionLockIsFree(stateRoot: linkedState)
    }

    // then
    #expect(error != nil)
    #expect(
      FileManager.default.fileExists(
        atPath: outside.appendingPathComponent("clawd.lock").path
      ) == false
    )
  }

  @Test func workerConfigurationSnapshotRejectsDotComponentsBeforeNormalization() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = root.appendingPathComponent("attempt.json")
    try Data("{}".utf8).write(to: configuration)
    let pathWithDotComponent =
      configuration.deletingLastPathComponent().path + "/./" + configuration.lastPathComponent

    // when
    let error = #expect(throws: EvaluationPathSecurityError.dotPathComponent(".")) {
      _ = try EvaluationWorkerConfigurationSnapshot.load(
        kind: .attempt,
        path: pathWithDotComponent
      )
    }

    // then
    #expect(error != nil)
  }

  @Test func durablePublicationRejectsLinksInTheDestinationPath() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: outside)
    let ancestorDestination = parentLink.appendingPathComponent("receipt.json")

    let leafTarget = root.appendingPathComponent("leaf-target.json")
    try Data("untouched".utf8).write(to: leafTarget)
    let leafDestination = root.appendingPathComponent("leaf-link.json")
    try FileManager.default.createSymbolicLink(at: leafDestination, withDestinationURL: leafTarget)

    // when
    let ancestorError = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(parentLink.lastPathComponent)
    ) {
      try EvaluationDurablePublication.publish(Data("blocked".utf8), to: ancestorDestination)
    }
    let leafError = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(leafDestination.lastPathComponent)
    ) {
      try EvaluationDurablePublication.publish(Data("blocked".utf8), to: leafDestination)
    }

    // then
    #expect(ancestorError != nil)
    #expect(leafError != nil)
    #expect(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("receipt.json").path)
        == false
    )
    #expect(try Data(contentsOf: leafTarget) == Data("untouched".utf8))
  }

  @Test func promotedLessonInstallationRejectsAMatchingSymlinkAtImmutablePath() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let sets = stateRoot.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
    let lesson = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "lesson_set_id": "candidate",
      "lessons": [],
      "schema_version": 1,
    ])
    let digest = SHA256Digest.hex(lesson)
    let external = root.appendingPathComponent("external.json")
    try lesson.write(to: external)
    let immutable = sets.appendingPathComponent("\(digest).json")
    try FileManager.default.createSymbolicLink(at: immutable, withDestinationURL: external)

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(immutable.lastPathComponent)
    ) {
      _ = try EvaluationWorkspaceMaterializer.installPromotedLessonSet(
        lesson,
        expectedDigest: digest,
        stateRoot: stateRoot
      )
    }

    // then
    #expect(error != nil)
    #expect(try Data(contentsOf: external) == lesson)
  }

  @Test(arguments: ["hardlink", "fifo"])
  func promotedLessonInstallationRejectsUnsafeExistingEntries(_ entryKind: String) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let sets = stateRoot.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
    let lesson = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "lesson_set_id": "candidate",
      "lessons": [],
      "schema_version": 1,
    ])
    let digest = SHA256Digest.hex(lesson)
    let immutable = sets.appendingPathComponent("\(digest).json")
    let external = root.appendingPathComponent("external.json")
    try lesson.write(to: external)
    switch entryKind {
    case "hardlink":
      try FileManager.default.linkItem(at: external, to: immutable)
    case "fifo":
      #expect(mkfifo(immutable.path, S_IRUSR | S_IWUSR) == 0)
    default:
      Issue.record("Unknown entry kind \(entryKind)")
    }

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.insecureFile(immutable.lastPathComponent)
    ) {
      _ = try EvaluationWorkspaceMaterializer.installPromotedLessonSet(
        lesson,
        expectedDigest: digest,
        stateRoot: stateRoot
      )
    }

    // then
    // The existing-entry idempotence branch may read only a private regular inode.
    #expect(error != nil)
    #expect(try Data(contentsOf: external) == lesson)
  }

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

  @Test func liveFreezeVerifierRejectsEveryRawPathBeforeNormalization() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    func dotted(_ path: String) -> String {
      let url = URL(fileURLWithPath: path)
      return url.deletingLastPathComponent().path + "/./" + url.lastPathComponent
    }
    let fields = [
      "repository", "manifest", "approval", "approval-body", "runtime", "receipt", "executable",
    ]
    let cases = fields.map { field in
      let inputs = EvaluationFreezeInputs(
        repositoryRoot: field == "repository"
          ? dotted(frozen.inputs.repositoryRoot) : frozen.inputs.repositoryRoot,
        manifestPath: field == "manifest"
          ? dotted(frozen.inputs.manifestPath) : frozen.inputs.manifestPath,
        manifestSHA256: frozen.inputs.manifestSHA256,
        approvalRecordPath: field == "approval"
          ? dotted(frozen.inputs.approvalRecordPath) : frozen.inputs.approvalRecordPath,
        approvalBodyPath: field == "approval-body"
          ? dotted(frozen.inputs.approvalBodyPath) : frozen.inputs.approvalBodyPath,
        runtimeConfigurationPath: field == "runtime"
          ? dotted(frozen.inputs.runtimeConfigurationPath) : frozen.inputs.runtimeConfigurationPath,
        receiptPath: field == "receipt"
          ? dotted(frozen.inputs.receiptPath) : frozen.inputs.receiptPath
      )
      let executablePath =
        field == "executable"
        ? dotted(frozen.executable.path) : frozen.executable.path
      return (inputs, executablePath)
    }

    // when
    var errors: [EvaluationPathSecurityError?] = []
    for (inputs, executablePath) in cases {
      let verifier = EvaluationLiveFreezeVerifier(runningExecutablePath: { executablePath })
      let error = await #expect(throws: EvaluationPathSecurityError.dotPathComponent(".")) {
        _ = try await verifier.verifyLocal(inputs)
      }
      errors.append(error)
    }

    // then
    // Each case kills standardize-before-guard at the public local-recheck seam.
    #expect(errors.count == fields.count)
    #expect(errors.allSatisfy { $0 != nil })
  }

  @Test func liveFreezeVerifierRejectsALinkedManifestModuleBeforePythonLaunch() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let runtimeURL = URL(fileURLWithPath: frozen.inputs.runtimeConfigurationPath)
    let runtimeData = try Data(contentsOf: runtimeURL)
    let executable = root.appendingPathComponent("bin/claw-eval")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let executableData = Data("test-executable".utf8)
    try executableData.write(to: executable)

    let tools = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let modulePaths = ["freeze.py"] + (1...7).map { "freeze_support_\($0).py" }
    let moduleData = Data("# frozen verifier module\n".utf8)
    var moduleRecords: [EvaluationManifestArtifact] = []
    for path in modulePaths {
      let url = tools.appendingPathComponent(path)
      try moduleData.write(to: url)
      moduleRecords.append(
        EvaluationManifestArtifact(
          role: "freeze_verifier_source",
          path: "tools/\(path)",
          bytes: moduleData.count,
          sha256: SHA256Digest.hex(moduleData)
        )
      )
    }
    let linkedModule = tools.appendingPathComponent(try #require(modulePaths.last))
    let linkTarget = root.appendingPathComponent("linked-module-target.py")
    try moduleData.write(to: linkTarget)
    try FileManager.default.removeItem(at: linkedModule)
    try FileManager.default.createSymbolicLink(at: linkedModule, withDestinationURL: linkTarget)

    let runtimeRecord = EvaluationManifestArtifact(
      role: "runtime",
      path: "config/runtime.json",
      bytes: runtimeData.count,
      sha256: SHA256Digest.hex(runtimeData)
    )
    let executableRecord = EvaluationManifestArtifact(
      role: "executable",
      path: "bin/claw-eval",
      bytes: executableData.count,
      sha256: SHA256Digest.hex(executableData)
    )
    let manifest = EvaluationFreezeManifest(
      categories: [
        "configuration": EvaluationManifestCategory(
          artifacts: [runtimeRecord] + moduleRecords,
          sha256: SHA256Digest.hex("configuration")
        ),
        "executable": EvaluationManifestCategory(
          artifacts: [executableRecord],
          sha256: SHA256Digest.hex("executable")
        ),
        "budget": EvaluationManifestCategory(
          artifacts: [],
          values: PageEvaluationContract.budgetManifestValues,
          sha256: SHA256Digest.hex("budget")
        ),
      ],
      protectedArtifacts: []
    )
    let manifestURL = root.appendingPathComponent("config/manifest.json")
    let manifestData = try EvaluationCanonicalJSON.data(encoding: manifest)
    try manifestData.write(to: manifestURL)
    let inputs = EvaluationFreezeInputs(
      repositoryRoot: root.path,
      manifestPath: manifestURL.path,
      manifestSHA256: SHA256Digest.hex(manifestData),
      approvalRecordPath: frozen.inputs.approvalRecordPath,
      approvalBodyPath: frozen.inputs.approvalBodyPath,
      runtimeConfigurationPath: runtimeURL.path,
      receiptPath: frozen.inputs.receiptPath
    )

    // when
    let error = await #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(linkedModule.lastPathComponent)
    ) {
      _ = try await EvaluationLiveFreezeVerifier(
        runningExecutablePath: { executable.path }
      ).verifyLocal(inputs)
    }

    // then
    #expect(error != nil)
  }

  @Test func conformancePreflightRefusesAReceiptCreatedWhileTheToolRuns() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let receipt = configured.configuration.evaluationRootURL
      .appendingPathComponent("receipts/conformance.json")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let relativeExecutable =
      "experiments/scheduled-task-learning/page-change/artifacts/page-conformance"
    let executable = root.appendingPathComponent(relativeExecutable)
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let occupant = Data("occupied".utf8)
    let executableData = Data(
      """
      #!/bin/sh
      mkdir -p '\(receipt.deletingLastPathComponent().path)'
      printf occupied > '\(receipt.path)'
      printf '%s' '{"conformance_id":"conformance-000000000000","passed":24,"schema_version":1,"total":24}'
      """.utf8
    )
    try executableData.write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    var categories = frozen.context.manifest.categories
    categories["conformance"] = EvaluationManifestCategory(
      artifacts: [
        EvaluationManifestArtifact(
          role: "executable",
          path: relativeExecutable,
          bytes: executableData.count,
          sha256: SHA256Digest.hex(executableData)
        )
      ],
      sha256: String(repeating: "a", count: 64)
    )
    let manifest = EvaluationFreezeManifest(
      schemaVersion: frozen.context.manifest.schemaVersion,
      decision: frozen.context.manifest.decision,
      experiment: frozen.context.manifest.experiment,
      protocolBinding: frozen.context.manifest.protocolBinding,
      categories: categories,
      protectedArtifacts: frozen.context.manifest.protectedArtifacts + [
        EvaluationManifestProtectedArtifact(
          path: relativeExecutable,
          bytes: executableData.count,
          sha256: SHA256Digest.hex(executableData)
        )
      ]
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: manifest,
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: frozen.context.runOrderJSON
    )

    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: EvaluationProtectedArtifactRunner(),
      launcher: ScriptedEvaluationWorkerLauncher { _, _, _ in
        EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
      }
    )

    // when
    let error = await #expect(
      throws: EvaluationPagePipelineError.protectedOutputExists(receipt.lastPathComponent)
    ) {
      _ = try await experiment.runConformance(
        freeze: context,
        receiptURL: receipt
      )
    }

    // then
    #expect(error != nil)
    #expect(try EvaluationPathSecurity.readRegularSingleLinkFile(at: receipt) == occupant)
  }

  @Test func protectedArtifactRunnerChecksTheWholeClosureBeforeAndAfterExecution() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let executableRelative = "tools/mutate-protected-sibling.sh"
    let siblingRelative = "artifacts/protected-sibling.txt"
    let executable = root.appendingPathComponent(executableRelative)
    let sibling = root.appendingPathComponent(siblingRelative)
    let marker = root.appendingPathComponent("runner-executed.txt")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sibling.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let executableData = Data(
      """
      #!/bin/sh
      if [ "$1" = "--output" ]; then
        /usr/bin/mkfifo "$2"
        exit 0
      fi
      printf ran > "$2"
      printf mutated > "$1"
      """.utf8
    )
    let siblingData = Data("frozen".utf8)
    try executableData.write(to: executable)
    try siblingData.write(to: sibling)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let artifactRecords = [
      EvaluationManifestArtifact(
        role: "executable",
        path: executableRelative,
        bytes: executableData.count,
        sha256: SHA256Digest.hex(executableData)
      ),
      EvaluationManifestArtifact(
        role: "sibling",
        path: siblingRelative,
        bytes: siblingData.count,
        sha256: SHA256Digest.hex(siblingData)
      ),
    ]
    var categories = frozen.context.manifest.categories
    categories["protected_runner_test"] = EvaluationManifestCategory(
      artifacts: artifactRecords,
      sha256: SHA256Digest.hex("protected-runner-test")
    )
    let manifest = EvaluationFreezeManifest(
      schemaVersion: frozen.context.manifest.schemaVersion,
      decision: frozen.context.manifest.decision,
      experiment: frozen.context.manifest.experiment,
      protocolBinding: frozen.context.manifest.protocolBinding,
      categories: categories,
      protectedArtifacts: frozen.context.manifest.protectedArtifacts
        + artifactRecords.map {
          EvaluationManifestProtectedArtifact(
            path: $0.path,
            bytes: $0.bytes,
            sha256: $0.sha256
          )
        }
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: manifest,
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: frozen.context.runOrderJSON
    )
    let runner = EvaluationProtectedArtifactRunner()

    // when
    // Pre-execution drift prevents launch.
    try Data("pre-mutated".utf8).write(to: sibling)
    let preExecutionError = await #expect(
      throws: EvaluationPagePipelineError.protectedArtifactChanged(siblingRelative)
    ) {
      _ = try await runner.run(
        relativeExecutablePath: executableRelative,
        arguments: [sibling.path, marker.path],
        protectedOutputURLs: [],
        freeze: context
      )
    }
    let markerExistedAfterPreExecutionDrift = FileManager.default.fileExists(atPath: marker.path)

    // A planted deterministic output is rejected before the tool can truncate it.
    try siblingData.write(to: sibling)
    let planted = root.appendingPathComponent("planted-output.json")
    let plantedData = Data("outside-evidence".utf8)
    try plantedData.write(to: planted)
    let plantedOutputError = await #expect(
      throws: EvaluationPagePipelineError.protectedOutputExists(planted.lastPathComponent)
    ) {
      _ = try await runner.run(
        relativeExecutablePath: executableRelative,
        arguments: [sibling.path, marker.path, "--output", planted.path],
        protectedOutputURLs: [planted],
        freeze: context
      )
    }
    let plantedContentsAfterRejection = try Data(contentsOf: planted)
    let markerExistedAfterPlantedOutput = FileManager.default.fileExists(atPath: marker.path)
    try FileManager.default.removeItem(at: planted)

    // A mutation performed by the invoked tool is caught before any next send.
    let postExecutionError = await #expect(
      throws: EvaluationPagePipelineError.protectedArtifactChanged(siblingRelative)
    ) {
      _ = try await runner.run(
        relativeExecutablePath: executableRelative,
        arguments: [sibling.path, marker.path],
        protectedOutputURLs: [],
        freeze: context
      )
    }
    let markerContentsAfterPostExecutionDrift = try Data(contentsOf: marker)

    // Metadata validation refuses a nonblocking FIFO instead of opening it as data.
    try siblingData.write(to: sibling)
    let fifo = root.appendingPathComponent("artifact-output.fifo")
    let missingOutputError = await #expect(
      throws: EvaluationPagePipelineError.protectedOutputMissing(fifo.lastPathComponent)
    ) {
      _ = try await runner.run(
        relativeExecutablePath: executableRelative,
        arguments: ["--output", fifo.path],
        protectedOutputURLs: [fifo],
        freeze: context
      )
    }
    try FileManager.default.removeItem(at: fifo)

    // A protected FIFO is rejected through the checked descriptor before launch.
    try FileManager.default.removeItem(at: sibling)
    try FileManager.default.removeItem(at: marker)
    let protectedFIFOCreationStatus = mkfifo(sibling.path, S_IRUSR | S_IWUSR)
    let protectedFIFOError = await #expect(
      throws: EvaluationPagePipelineError.protectedArtifactChanged(siblingRelative)
    ) {
      _ = try await runner.run(
        relativeExecutablePath: executableRelative,
        arguments: [sibling.path, marker.path],
        protectedOutputURLs: [],
        freeze: context
      )
    }
    let markerExistedAfterProtectedFIFO = FileManager.default.fileExists(atPath: marker.path)

    // then
    #expect(preExecutionError != nil)
    #expect(markerExistedAfterPreExecutionDrift == false)
    #expect(plantedOutputError != nil)
    #expect(plantedContentsAfterRejection == plantedData)
    #expect(markerExistedAfterPlantedOutput == false)
    #expect(postExecutionError != nil)
    #expect(markerContentsAfterPostExecutionDrift == Data("ran".utf8))
    #expect(missingOutputError != nil)
    #expect(protectedFIFOCreationStatus == 0)
    #expect(protectedFIFOError != nil)
    #expect(markerExistedAfterProtectedFIFO == false)
  }
}
