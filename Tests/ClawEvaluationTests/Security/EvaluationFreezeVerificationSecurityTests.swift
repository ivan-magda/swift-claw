import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

extension EvaluationFilesystemSecurityTests {
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
}
