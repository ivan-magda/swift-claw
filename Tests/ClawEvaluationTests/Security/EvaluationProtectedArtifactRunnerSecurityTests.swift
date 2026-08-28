import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

extension EvaluationFilesystemSecurityTests {
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
