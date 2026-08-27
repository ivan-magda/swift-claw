import ClawCore
import ClawSubprocess
import Foundation

// swiftlint:disable file_length

package struct EvaluationFreezeInputs: Codable, Sendable, Equatable {
  let repositoryRoot: String
  let manifestPath: String
  let manifestSHA256: String
  let approvalRecordPath: String
  let approvalBodyPath: String
  let runtimeConfigurationPath: String
  let receiptPath: String

  enum CodingKeys: String, CodingKey {
    case repositoryRoot = "repository_root"
    case manifestPath = "manifest_path"
    case manifestSHA256 = "manifest_sha256"
    case approvalRecordPath = "approval_record_path"
    case approvalBodyPath = "approval_body_path"
    case runtimeConfigurationPath = "runtime_configuration_path"
    case receiptPath = "receipt_path"
  }
}

struct EvaluationManifestArtifact: Codable, Sendable, Equatable {
  package let role: String
  package let path: String
  package let bytes: Int
  package let sha256: String
}

struct EvaluationManifestCategory: Codable, Sendable, Equatable {
  package let artifacts: [EvaluationManifestArtifact]
  package let values: JSONValue
  package let sha256: String

  package init(
    artifacts: [EvaluationManifestArtifact],
    values: JSONValue = .object([:]),
    sha256: String
  ) {
    self.artifacts = artifacts
    self.values = values
    self.sha256 = sha256
  }
}

struct EvaluationFreezeManifest: Codable, Sendable, Equatable {
  package let schemaVersion: Int?
  package let decision: String?
  package let experiment: String?
  package let protocolBinding: EvaluationManifestProtocolBinding?
  package let categories: [String: EvaluationManifestCategory]
  package let protectedArtifacts: [EvaluationManifestProtectedArtifact]

  package init(
    schemaVersion: Int? = nil,
    decision: String? = nil,
    experiment: String? = nil,
    protocolBinding: EvaluationManifestProtocolBinding? = nil,
    categories: [String: EvaluationManifestCategory],
    protectedArtifacts: [EvaluationManifestProtectedArtifact]
  ) {
    self.schemaVersion = schemaVersion
    self.decision = decision
    self.experiment = experiment
    self.protocolBinding = protocolBinding
    self.categories = categories
    self.protectedArtifacts = protectedArtifacts
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case decision, experiment
    case protocolBinding = "protocol"
    case categories
    case protectedArtifacts = "protected_artifacts"
  }

  package func artifact(role: String, category: String) -> EvaluationManifestArtifact? {
    categories[category]?.artifacts.first { $0.role == role }
  }

  func artifacts(role: String, category: String) -> [EvaluationManifestArtifact] {
    categories[category]?.artifacts.filter { $0.role == role } ?? []
  }

  package func artifact(relativePath: String) -> EvaluationManifestProtectedArtifact? {
    protectedArtifacts.first { $0.path == relativePath }
  }

  func validateBudgetContract() throws {
    guard categories["budget"]?.values == PageEvaluationContract.budgetManifestValues else {
      throw EvaluationFreezeError.budgetContractMismatch
    }
  }
}

struct EvaluationManifestProtocolBinding: Codable, Sendable, Equatable {
  package let version: String
  package let path: String
  package let bytes: Int
  package let sha256: String
}

struct EvaluationManifestProtectedArtifact: Codable, Sendable, Equatable {
  package let path: String
  package let bytes: Int
  package let sha256: String
}

struct EvaluationFreezeReceipt: Codable, Sendable, Equatable {
  package struct FileBinding: Codable, Sendable, Equatable {
    package let path: String
    package let bytes: Int
    package let sha256: String
    package let gitMode: String
    package let format: String?

    enum CodingKeys: String, CodingKey {
      case path, bytes, sha256
      case gitMode = "git_mode"
      case format
    }
  }

  package struct ManifestBinding: Codable, Sendable, Equatable {
    package let path: String
    package let sha256: String
  }

  package struct Author: Codable, Sendable, Equatable {
    package let login: String
    package let id: Int64
    package let nodeID: String

    enum CodingKeys: String, CodingKey {
      case login, id
      case nodeID = "node_id"
    }
  }

  package struct Comment: Codable, Sendable, Equatable {
    package let id: Int64
    package let nodeID: String
    package let author: Author
    package let createdAt: String
    package let updatedAt: String
    package let bodySHA256: String

    enum CodingKeys: String, CodingKey {
      case id
      case nodeID = "node_id"
      case author
      case createdAt = "created_at"
      case updatedAt = "updated_at"
      case bodySHA256 = "body_sha256"
    }
  }

  package let schemaVersion: Int
  package let status: String
  package let verifiedAt: String
  package let decision: String
  package let experiment: String
  package let manifest: ManifestBinding
  package let verifier: FileBinding
  package let verifierModules: [FileBinding]
  package let freezeCommit: String
  package let comment: Comment
  package let executable: FileBinding

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case status
    case verifiedAt = "verified_at"
    case decision, experiment, manifest, verifier
    case verifierModules = "verifier_modules"
    case freezeCommit = "freeze_commit"
    case comment, executable
  }
}

struct EvaluationRuntimeBindingReceipt: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let status: String
  let manifestSHA256: String
  let verifier: EvaluationFreezeReceipt.FileBinding
  let verifierModules: [EvaluationFreezeReceipt.FileBinding]
  let executable: EvaluationFreezeReceipt.FileBinding

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case status
    case manifestSHA256 = "manifest_sha256"
    case verifier
    case verifierModules = "verifier_modules"
    case executable
  }
}

struct EvaluationFreezeContext: Sendable, Equatable {
  package let repositoryRoot: String
  package let manifest: EvaluationFreezeManifest
  package let receipt: EvaluationFreezeReceipt
  package let runtime: EvaluationRuntimeConfiguration
  package let runOrderJSON: Data

  package init(
    repositoryRoot: String,
    manifest: EvaluationFreezeManifest,
    receipt: EvaluationFreezeReceipt,
    runtime: EvaluationRuntimeConfiguration,
    runOrderJSON: Data
  ) {
    self.repositoryRoot = repositoryRoot
    self.manifest = manifest
    self.receipt = receipt
    self.runtime = runtime
    self.runOrderJSON = runOrderJSON
  }

  /// Equality of the approved trust binding. `verified_at` is intentionally excluded because every
  /// live recheck produces a fresh observation timestamp even when all approved bytes are unchanged.
  package func hasSameApprovedBinding(as other: Self) -> Bool {
    repositoryRoot == other.repositoryRoot
      && manifest == other.manifest
      && runtime == other.runtime
      && runOrderJSON == other.runOrderJSON
      && receipt.schemaVersion == other.receipt.schemaVersion
      && receipt.status == other.receipt.status
      && receipt.decision == other.receipt.decision
      && receipt.experiment == other.receipt.experiment
      && receipt.manifest == other.receipt.manifest
      && receipt.verifier == other.receipt.verifier
      && receipt.verifierModules == other.receipt.verifierModules
      && receipt.freezeCommit == other.receipt.freezeCommit
      && receipt.comment == other.receipt.comment
      && receipt.executable == other.receipt.executable
  }
}

protocol EvaluationFreezeVerifying: Sendable {
  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext
  func verifyLocal(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext
}

extension EvaluationFreezeVerifying {
  func verifyLocal(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    try await verify(inputs)
  }
}

struct EvaluationLiveFreezeVerifier: EvaluationFreezeVerifying {
  private let runningExecutablePath: @Sendable () -> String

  package init(
    runningExecutablePath: @escaping @Sendable () -> String = { CommandLine.arguments[0] }
  ) {
    self.runningExecutablePath = runningExecutablePath
  }

  package func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    let prepared = try prepare(inputs)
    try prepared.verifyProtectedInputs()
    let receipt = try await runLiveVerifier(
      verifierURL: prepared.verifierURL,
      inputs: inputs,
      executableURL: prepared.executableURL
    )
    try prepared.verifyProtectedInputs()
    try Self.validate(
      receipt: receipt,
      inputs: inputs,
      verifierModules: prepared.verifierModules,
      executable: prepared.executableRecord
    )
    try prepared.verifyProtectedInputs()
    let order = try await deriveRunOrder(
      verifierURL: prepared.verifierURL,
      manifestURL: prepared.manifestURL,
      manifestSHA256: inputs.manifestSHA256
    )
    try prepared.verifyProtectedInputs()
    return prepared.context(receipt: receipt, runOrderJSON: order)
  }

  func verifyLocal(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    let prepared = try prepare(inputs)
    try prepared.verifyProtectedInputs()
    let receiptData = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: prepared.receiptURL
    )
    let receipt = try Self.decodeCanonical(
      EvaluationFreezeReceipt.self,
      from: receiptData,
      error: EvaluationFreezeError.invalidLiveReceipt
    )
    try Self.validate(
      receipt: receipt,
      inputs: inputs,
      verifierModules: prepared.verifierModules,
      executable: prepared.executableRecord
    )
    try prepared.verifyProtectedInputs()
    let local = try await runLocalVerifier(
      verifierURL: prepared.verifierURL,
      inputs: inputs,
      executableURL: prepared.executableURL
    )
    try prepared.verifyProtectedInputs()
    try Self.validate(
      receipt: local,
      inputs: inputs,
      verifierModules: prepared.verifierModules,
      executable: prepared.executableRecord
    )
    try prepared.verifyProtectedInputs()
    let order = try await deriveRunOrder(
      verifierURL: prepared.verifierURL,
      manifestURL: prepared.manifestURL,
      manifestSHA256: inputs.manifestSHA256
    )
    try prepared.verifyProtectedInputs()
    return prepared.context(receipt: receipt, runOrderJSON: order)
  }
}

private extension EvaluationLiveFreezeVerifier {
  struct Prepared {
    let root: URL
    let manifestURL: URL
    let manifestSHA256: String
    let manifest: EvaluationFreezeManifest
    let runtime: EvaluationRuntimeConfiguration
    let runtimeURL: URL
    let runtimeRecord: EvaluationManifestArtifact
    let receiptURL: URL
    let verifierURL: URL
    let verifierModules: [EvaluationManifestArtifact]
    let verifierModuleURLs: [URL]
    let executableURL: URL
    let executableRecord: EvaluationManifestArtifact
    let guardedInputURLs: [URL]

    func verifyProtectedInputs() throws {
      try EvaluationPathSecurity.rejectSymlinkComponents(in: guardedInputURLs)
      let manifestData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: manifestURL)
      guard SHA256Digest.hex(manifestData) == manifestSHA256 else {
        throw EvaluationFreezeError.manifestDigestMismatch
      }
      for (record, url) in zip(verifierModules, verifierModuleURLs) {
        try EvaluationLiveFreezeVerifier.verifyFile(url, against: record, under: root)
      }
      try EvaluationLiveFreezeVerifier.verifyFile(runtimeURL, against: runtimeRecord, under: root)
      try EvaluationLiveFreezeVerifier.verifyFile(
        executableURL,
        against: executableRecord,
        under: root
      )
    }

    func context(receipt: EvaluationFreezeReceipt, runOrderJSON: Data) -> EvaluationFreezeContext {
      EvaluationFreezeContext(
        repositoryRoot: root.path,
        manifest: manifest,
        receipt: receipt,
        runtime: runtime,
        runOrderJSON: runOrderJSON
      )
    }
  }

  // swiftlint:disable:next function_body_length
  func prepare(_ inputs: EvaluationFreezeInputs) throws -> Prepared {
    let inputPathStrings = [
      inputs.repositoryRoot,
      inputs.manifestPath,
      inputs.approvalRecordPath,
      inputs.approvalBodyPath,
      inputs.runtimeConfigurationPath,
      inputs.receiptPath,
    ]
    guard inputPathStrings.allSatisfy({ $0.hasPrefix("/") }) else {
      throw EvaluationFreezeError.missingProtectedBinding
    }
    let inputURLs = inputPathStrings.map { URL(fileURLWithPath: $0) }
    let executablePath = runningExecutablePath()
    let executableComponents = executablePath.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    let hasUnsafeExecutableComponent = executableComponents.enumerated().contains { index, value in
      value == "." || value == ".."
        || (value.isEmpty && !(index == 0 && executablePath.hasPrefix("/")))
    }
    if let dotComponent = executableComponents.first(where: { $0 == "." || $0 == ".." }) {
      throw EvaluationPathSecurityError.dotPathComponent(String(dotComponent))
    }
    guard
      executablePath.isEmpty == false,
      hasUnsafeExecutableComponent == false
    else { throw EvaluationFreezeError.runtimeConfigurationPathMismatch }
    let rawRunningExecutable =
      executablePath.hasPrefix("/")
      ? URL(fileURLWithPath: executablePath)
      : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(executablePath)
    try EvaluationPathSecurity.rejectSymlinkComponents(in: inputURLs + [rawRunningExecutable])

    let root = inputURLs[0].standardizedFileURL
    let manifestURL = inputURLs[1].standardizedFileURL
    let manifestData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: manifestURL)
    guard SHA256Digest.hex(manifestData) == inputs.manifestSHA256 else {
      throw EvaluationFreezeError.manifestDigestMismatch
    }
    let manifest = try JSONDecoder().decode(EvaluationFreezeManifest.self, from: manifestData)
    try manifest.validateBudgetContract()
    let runtimeURL = inputURLs[4].standardizedFileURL
    try EvaluationPathSecurity.requireRegularSingleLinkFile(at: runtimeURL)
    let runtime = try EvaluationRuntimeConfiguration.load(from: runtimeURL)
    let receiptURL = inputURLs[5].standardizedFileURL
    guard EvaluationPathSecurity.isStrictlyContained(receiptURL, under: runtime.evaluationRootURL),
      let executable = manifest.artifact(role: "executable", category: "executable"),
      executable.path == runtime.executablePath,
      let runtimeRecord = manifest.artifact(role: "runtime", category: "configuration")
    else { throw EvaluationFreezeError.missingProtectedBinding }
    let modules = manifest.artifacts(role: "freeze_verifier_source", category: "configuration")
      .sorted { $0.path < $1.path }
    guard modules.count == 8,
      let verifier = modules.first(where: { $0.path == runtime.freezeVerifierPath })
    else { throw EvaluationFreezeError.missingProtectedBinding }
    let verifierModuleURLs = try modules.map { try Self.artifactURL($0, under: root) }
    guard let verifierIndex = modules.firstIndex(where: { $0.path == verifier.path }) else {
      throw EvaluationFreezeError.missingProtectedBinding
    }
    let verifierURL = verifierModuleURLs[verifierIndex]
    let executableURL = try Self.artifactURL(executable, under: root)
    let protectedRuntimeURL = try Self.artifactURL(runtimeRecord, under: root)
    guard runtimeURL == protectedRuntimeURL,
      rawRunningExecutable.resolvingSymlinksInPath()
        == executableURL.resolvingSymlinksInPath()
    else { throw EvaluationFreezeError.runtimeConfigurationPathMismatch }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [receiptURL.deletingLastPathComponent(), receiptURL]
    )
    for (module, url) in zip(modules, verifierModuleURLs) {
      try Self.verifyFile(url, against: module, under: root)
    }
    try Self.verifyFile(runtimeURL, against: runtimeRecord, under: root)
    try Self.verifyFile(executableURL, against: executable, under: root)
    return Prepared(
      root: root,
      manifestURL: manifestURL,
      manifestSHA256: inputs.manifestSHA256,
      manifest: manifest,
      runtime: runtime,
      runtimeURL: runtimeURL,
      runtimeRecord: runtimeRecord,
      receiptURL: receiptURL,
      verifierURL: verifierURL,
      verifierModules: modules,
      verifierModuleURLs: verifierModuleURLs,
      executableURL: executableURL,
      executableRecord: executable,
      guardedInputURLs: inputURLs + [rawRunningExecutable]
    )
  }

  static func verifyFile(
    _ url: URL,
    against artifact: EvaluationManifestArtifact,
    under root: URL
  ) throws {
    do {
      let observed = try EvaluationManifestBoundArtifactReader.read(
        relativePath: artifact.path,
        expectedByteCount: artifact.bytes,
        expectedSHA256: artifact.sha256,
        repositoryRoot: root
      )
      guard observed.url == url.standardizedFileURL else {
        throw EvaluationFreezeError.protectedFileMismatch(artifact.path)
      }
    } catch {
      throw EvaluationFreezeError.protectedFileMismatch(artifact.path)
    }
  }

  static func artifactURL(
    _ artifact: EvaluationManifestArtifact,
    under root: URL
  ) throws -> URL {
    do {
      return try EvaluationManifestBoundArtifactReader.resolve(
        relativePath: artifact.path,
        repositoryRoot: root
      )
    } catch let error as EvaluationPathSecurityError {
      throw error
    } catch {
      throw EvaluationFreezeError.missingProtectedBinding
    }
  }

  static func validate(
    receipt: EvaluationFreezeReceipt,
    inputs: EvaluationFreezeInputs,
    verifierModules: [EvaluationManifestArtifact],
    executable: EvaluationManifestArtifact
  ) throws {
    guard let verifier = verifierModules.first(where: { $0.path == receipt.verifier.path }) else {
      throw EvaluationFreezeError.invalidLiveReceipt
    }
    guard
      receipt.schemaVersion == 1,
      receipt.status == "verified",
      receipt.decision == "D6",
      receipt.experiment == "page-change",
      receipt.manifest.sha256 == inputs.manifestSHA256,
      receipt.verifier.path == verifier.path,
      receipt.verifier.bytes == verifier.bytes,
      receipt.verifier.sha256 == verifier.sha256,
      receipt.verifier.gitMode == "100644",
      receipt.executable.path == executable.path,
      receipt.executable.bytes == executable.bytes,
      receipt.executable.sha256 == executable.sha256,
      receipt.executable.gitMode == "100755",
      receipt.executable.format == "mach-o-arm64",
      receipt.comment.createdAt == receipt.comment.updatedAt
    else {
      throw EvaluationFreezeError.invalidLiveReceipt
    }
    try validateVerifierModules(
      receipt.verifierModules,
      expected: verifierModules,
      error: EvaluationFreezeError.invalidLiveReceipt
    )
  }

  static func validate(
    receipt: EvaluationRuntimeBindingReceipt,
    inputs: EvaluationFreezeInputs,
    verifierModules: [EvaluationManifestArtifact],
    executable: EvaluationManifestArtifact
  ) throws {
    guard let verifier = verifierModules.first(where: { $0.path == receipt.verifier.path }) else {
      throw EvaluationFreezeError.invalidLocalReceipt
    }
    guard
      receipt.schemaVersion == 1,
      receipt.status == "verified",
      receipt.manifestSHA256 == inputs.manifestSHA256,
      receipt.verifier.path == verifier.path,
      receipt.verifier.bytes == verifier.bytes,
      receipt.verifier.sha256 == verifier.sha256,
      receipt.verifier.gitMode == "100644",
      receipt.verifier.format == nil,
      receipt.executable.path == executable.path,
      receipt.executable.bytes == executable.bytes,
      receipt.executable.sha256 == executable.sha256,
      receipt.executable.gitMode == "100755",
      receipt.executable.format == "mach-o-arm64"
    else {
      throw EvaluationFreezeError.invalidLocalReceipt
    }
    try validateVerifierModules(
      receipt.verifierModules,
      expected: verifierModules,
      error: EvaluationFreezeError.invalidLocalReceipt
    )
  }

  static func validateVerifierModules(
    _ observed: [EvaluationFreezeReceipt.FileBinding],
    expected: [EvaluationManifestArtifact],
    error: EvaluationFreezeError
  ) throws {
    let observed = observed.sorted { $0.path < $1.path }
    let expected = expected.sorted { $0.path < $1.path }
    guard observed.count == expected.count else { throw error }
    for (binding, artifact) in zip(observed, expected) {
      guard
        binding.path == artifact.path,
        binding.bytes == artifact.bytes,
        binding.sha256 == artifact.sha256,
        binding.gitMode == "100644",
        binding.format == nil
      else { throw error }
    }
  }

  func runLiveVerifier(
    verifierURL: URL,
    inputs: EvaluationFreezeInputs,
    executableURL: URL
  ) async throws -> EvaluationFreezeReceipt {
    let output = try await runVerifier(
      verifierURL: verifierURL,
      arguments: [
        "verify-live-freeze",
        "--repo-root", inputs.repositoryRoot,
        "--manifest", inputs.manifestPath,
        "--approval", inputs.approvalRecordPath,
        "--approval-body", inputs.approvalBodyPath,
        "--executable", executableURL.path,
        "--receipt-output", inputs.receiptPath,
      ],
      timeout: .seconds(60),
      captureLimit: 32_768,
      failure: .liveVerificationFailed
    )
    return try Self.decodeCanonical(
      EvaluationFreezeReceipt.self,
      from: output,
      error: EvaluationFreezeError.invalidLiveReceipt
    )
  }

  func runLocalVerifier(
    verifierURL: URL,
    inputs: EvaluationFreezeInputs,
    executableURL: URL
  ) async throws -> EvaluationRuntimeBindingReceipt {
    let output = try await runVerifier(
      verifierURL: verifierURL,
      arguments: [
        "verify-runtime-binding",
        "--repo-root", inputs.repositoryRoot,
        "--manifest", inputs.manifestPath,
        "--manifest-sha256", inputs.manifestSHA256,
        "--executable", executableURL.path,
      ],
      timeout: .seconds(30),
      captureLimit: 32_768,
      failure: .localVerificationFailed
    )
    return try Self.decodeCanonical(
      EvaluationRuntimeBindingReceipt.self,
      from: output,
      error: EvaluationFreezeError.invalidLocalReceipt
    )
  }

  func deriveRunOrder(
    verifierURL: URL,
    manifestURL: URL,
    manifestSHA256: String
  ) async throws -> Data {
    let output = try await runVerifier(
      verifierURL: verifierURL,
      arguments: [
        "derive-run-order",
        "--manifest", manifestURL.path,
        "--manifest-sha256", manifestSHA256,
      ],
      timeout: .seconds(30),
      captureLimit: 1_048_576,
      failure: .runOrderDerivationFailed
    )
    _ = try JSONSerialization.jsonObject(with: output)
    return output
  }

  private func runVerifier(
    verifierURL: URL,
    arguments: [String],
    timeout: Duration,
    captureLimit: Int,
    failure: EvaluationFreezeError
  ) async throws -> Data {
    let result = await SwiftSubprocessRunner(executablePath: "/usr/bin/python3").run(
      SubprocessCommand(
        arguments: ["-I", verifierURL.path] + arguments,
        timeout: timeout,
        captureLimit: captureLimit,
        teardownGracePeriod: .seconds(2)
      )
    )
    guard case .exited(0) = result.termination, result.stdout.truncated == false else {
      throw failure
    }
    return result.stdout.bytes
  }

  static func decodeCanonical<Value: Codable>(
    _ type: Value.Type,
    from data: Data,
    error: EvaluationFreezeError
  ) throws -> Value {
    let value: Value
    do {
      value = try JSONDecoder().decode(type, from: data)
    } catch {
      throw error
    }
    guard (try? EvaluationCanonicalJSON.data(encoding: value)) == data else { throw error }
    return value
  }
}

enum EvaluationFreezeError: Error, Sendable, Equatable {
  case manifestDigestMismatch
  case budgetContractMismatch
  case missingProtectedBinding
  case runtimeConfigurationPathMismatch
  case protectedFileMismatch(String)
  case liveVerificationFailed
  case localVerificationFailed
  case invalidLiveReceipt
  case invalidLocalReceipt
  case runOrderDerivationFailed
}
