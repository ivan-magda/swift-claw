import ClawCore
import Foundation

public struct ExecuteCodeSettings: Sendable, Equatable {
  public let memoryMiB: Int
  public let cpus: Int
  public let timeout: Duration
  public let allowEgress: Bool

  public init(memoryMiB: Int, cpus: Int, timeout: Duration, allowEgress: Bool) {
    self.memoryMiB = memoryMiB
    self.cpus = cpus
    self.timeout = timeout
    self.allowEgress = allowEgress
  }
}

public struct ExecuteCodeTool: Tool {
  public static let maxCodeBytes = 16 * 1024
  public static let maxStagedFileBytes = 1024 * 1024
  public static let maxStagedTotalBytes = 4 * 1024 * 1024
  public static let maxStagedFiles = 16
  public static let rawOutputTruncationNotice =
    "[raw output truncated after the first 1 MiB of one or more streams]"

  let workspaceRoot: URL
  let backend: any ExecutionBackend
  let settings: ExecuteCodeSettings
  let redactor: SecretRedactor

  public init(
    workspaceRoot: URL,
    backend: any ExecutionBackend,
    settings: ExecuteCodeSettings,
    redactor: SecretRedactor
  ) {
    self.workspaceRoot = workspaceRoot
    self.backend = backend
    self.settings = settings
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "execute_code",
      description:
        "Run a short Python or shell script in a locked-down, throwaway sandbox (owner approval required; no network unless explicitly requested).",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "language": .object([
            "type": .string("string"),
            "enum": .array([.string("python"), .string("sh")]),
          ]),
          "code": .object(["type": .string("string")]),
          "stage": .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
          ]),
          "network": .object([
            "type": .string("boolean"),
            "default": .bool(false),
          ]),
        ]),
        "required": .array([.string("language"), .string("code")]),
      ]),
      egressClass: .none,
      riskLevel: .dangerous
    )
  }

  public var timeout: Duration {
    settings.timeout + .seconds(20)
  }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    nil
  }

  public func prepareAction(arguments: JSONValue) async -> PreparedActionResolution? {
    guard let raw = Self.decode(RawArguments.self, from: arguments) else {
      return .refused(
        reason: "execute_code needs language, code, stage, and network in their declared types."
      )
    }
    guard let language = ExecLanguage(rawValue: raw.language) else {
      return .refused(reason: "execute_code supports only python and sh.")
    }
    guard raw.code.utf8.count <= Self.maxCodeBytes else {
      return .refused(reason: "The script exceeds the 16 KiB code cap.")
    }

    let paths = raw.stage ?? []
    guard paths.count <= Self.maxStagedFiles else {
      return .refused(reason: "execute_code stages at most 16 files.")
    }
    let network = raw.network ?? false
    guard network == false || settings.allowEgress else {
      return .refused(reason: "Networked code execution is disabled by configuration.")
    }

    switch authorizeAndLoad(paths: paths) {
    case .failure(let reason):
      return .refused(reason: reason)
    case .success(let loaded):
      let privateData = loaded.contains { stage in
        isPrivate(realpath: stage.record.realpath)
      }
      let recorded = RecordedArguments(
        code: raw.code,
        language: language,
        network: network,
        readsPrivateData: privateData,
        stage: loaded.map(\.record)
      )
      guard let canonicalArgsJSON = Self.canonicalJSON(recorded) else {
        return .refused(reason: "The prepared code action could not be encoded safely.")
      }
      let target =
        "code_exec:\(language.rawValue):"
        + String(SHA256Digest.hex(Data(canonicalArgsJSON.utf8)).prefix(16))
      return .prepared(
        PreparedToolAction(
          canonicalTarget: target,
          canonicalArgsJSON: canonicalArgsJSON,
          presentation: approvalPresentation(raw: raw, recorded: recorded),
          guardTexts: [raw.code] + loaded.map(\.guardText),
          canExfiltrate: network
        )
      )
    }
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    guard let approvedTarget = canonicalTarget else {
      return errorPayload("execute_code was dispatched without its approved target.")
    }
    guard let recorded = Self.decode(RecordedArguments.self, from: arguments) else {
      return errorPayload("The recorded code action is unreadable; nothing ran.")
    }
    guard let canonicalArgsJSON = Self.canonicalJSON(recorded) else {
      return errorPayload("The recorded code action cannot be re-encoded safely; nothing ran.")
    }
    let expectedTarget =
      "code_exec:\(recorded.language.rawValue):"
      + String(SHA256Digest.hex(Data(canonicalArgsJSON.utf8)).prefix(16))
    guard expectedTarget == approvedTarget else {
      return errorPayload(
        "The recorded code action no longer matches its approved target; nothing ran."
      )
    }
    guard recorded.code.utf8.count <= Self.maxCodeBytes else {
      return errorPayload("The recorded script exceeds the approved code cap; nothing ran.")
    }
    guard recorded.network == false || settings.allowEgress else {
      return errorPayload("Networked execution is no longer enabled; nothing ran.")
    }

    let loaded: [LoadedStage]
    switch reloadRecordedStages(recorded.stage) {
    case .failure(let reason):
      return errorPayload(reason)
    case .success(let stages):
      loaded = stages
    }
    let privateData = loaded.contains { stage in
      isPrivate(realpath: stage.record.realpath)
    }
    guard privateData == recorded.readsPrivateData else {
      return errorPayload(
        "The staged private-data classification changed after approval; nothing ran."
      )
    }

    let entrypoint = StagedFile(
      name: recorded.language == .python ? ".clawd-entrypoint.py" : ".clawd-entrypoint.sh",
      bytes: Data(recorded.code.utf8),
      mode: .readExecute
    )
    let request = ExecutionRequest(
      language: recorded.language,
      entrypoint: entrypoint,
      inputs: loaded.map { stage in
        StagedFile(name: stage.basename, bytes: stage.bytes, mode: .readOnly)
      },
      network: recorded.network,
      timeout: settings.timeout
    )
    return map(result: await backend.run(request), readsPrivateData: recorded.readsPrivateData)
  }
}

// MARK: - Argument Values

private extension ExecuteCodeTool {
  struct RawArguments: Codable {
    let language: String
    let code: String
    let stage: [String]?
    let network: Bool?
  }

  struct RecordedStage: Codable, Equatable {
    let bytes: Int
    let path: String
    let realpath: String
    let sha256: String
  }

  struct RecordedArguments: Codable, Equatable {
    let code: String
    let language: ExecLanguage
    let network: Bool
    let readsPrivateData: Bool
    let stage: [RecordedStage]
  }

  struct AuthorizedStage {
    let path: String
    let realpath: String
    let basename: String
  }

  struct LoadedStage {
    let record: RecordedStage
    let basename: String
    let bytes: Data

    var guardText: String {
      String(decoding: bytes, as: UTF8.self)
    }
  }
}

// MARK: - Staging Authorization

private extension ExecuteCodeTool {
  enum StageLoadResult {
    case success([LoadedStage])
    case failure(String)
  }

  func authorizeAndLoad(paths: [String]) -> StageLoadResult {
    guard WorkspacePathContainment.canonicalPath(workspaceRoot.path) != nil else {
      return .failure("The workspace root is unavailable.")
    }

    var authorized: [AuthorizedStage] = []
    var normalizedNames = Set<String>()
    var totalStatBytes = 0

    for path in paths {
      let realpath: String
      switch WorkspacePathContainment.resolveExisting(path: path, root: workspaceRoot.path) {
      case .refused(let reason):
        return .failure(reason)
      case .resolved(let resolved):
        realpath = resolved
      }

      let attributes: [FileAttributeKey: Any]
      do {
        attributes = try FileManager.default.attributesOfItem(atPath: realpath)
      } catch {
        return .failure("A staged file became unavailable before it could be inspected.")
      }
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        return .failure("Every staged path must resolve to a regular file.")
      }
      guard let number = attributes[.size] as? NSNumber else {
        return .failure("A staged file size could not be determined.")
      }
      let statBytes = number.intValue
      guard statBytes <= Self.maxStagedFileBytes else {
        return .failure("A staged file exceeds the 1 MiB per-file cap.")
      }
      let (nextTotal, overflow) = totalStatBytes.addingReportingOverflow(statBytes)
      guard overflow == false, nextTotal <= Self.maxStagedTotalBytes else {
        return .failure("Staged files exceed the 4 MiB total cap.")
      }
      totalStatBytes = nextTotal

      let basename = (path as NSString).lastPathComponent
      let normalized = Self.normalizedBasename(basename)
      guard normalized.hasPrefix(".clawd-entrypoint.") == false else {
        return .failure("Staged files may not use the reserved .clawd-entrypoint.* namespace.")
      }
      guard normalizedNames.insert(normalized).inserted else {
        return .failure("Staged files must have unique flat basenames.")
      }

      authorized.append(
        AuthorizedStage(
          path: path,
          realpath: realpath,
          basename: basename
        )
      )
    }

    var loaded: [LoadedStage] = []
    var totalReadBytes = 0
    for stage in authorized {
      let data: Data
      do {
        guard
          let bounded = try Self.readBoundedFile(
            atPath: stage.realpath,
            maxBytes: Self.maxStagedFileBytes
          )
        else {
          return .failure("A staged file grew past the 1 MiB cap while it was read.")
        }
        data = bounded
      } catch {
        return .failure("A staged file became unreadable before it could be prepared.")
      }
      let (nextTotal, overflow) = totalReadBytes.addingReportingOverflow(data.count)
      guard overflow == false, nextTotal <= Self.maxStagedTotalBytes else {
        return .failure("Staged files grew past the 4 MiB total cap while they were read.")
      }
      totalReadBytes = nextTotal

      loaded.append(
        LoadedStage(
          record: RecordedStage(
            bytes: data.count,
            path: stage.path,
            realpath: stage.realpath,
            sha256: SHA256Digest.hex(data)
          ),
          basename: stage.basename,
          bytes: data
        )
      )
    }

    return .success(loaded)
  }
}

extension ExecuteCodeTool {
  static func readBoundedFile(atPath path: String, maxBytes: Int) throws -> Data? {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }

    var data = Data()
    while data.count <= maxBytes {
      let remaining = maxBytes + 1 - data.count
      guard let chunk = try handle.read(upToCount: remaining), chunk.isEmpty == false else {
        return data
      }
      data.append(chunk)
    }

    return nil
  }
}

private extension ExecuteCodeTool {
  enum BasenameValidation {
    case accepted(String)
    case reservedNamespace
    case duplicate
  }

  static func validateBasename(
    of path: String,
    claimed normalizedNames: inout Set<String>
  ) -> BasenameValidation {
    let basename = (path as NSString).lastPathComponent
    let normalized = normalizedBasename(basename)

    guard normalized.hasPrefix(".clawd-entrypoint.") == false else {
      return .reservedNamespace
    }

    guard normalizedNames.insert(normalized).inserted else {
      return .duplicate
    }

    return .accepted(basename)
  }

  static func totalWithinCap(adding bytes: Int, to total: Int) -> Int? {
    let (nextTotal, overflow) = total.addingReportingOverflow(bytes)

    guard overflow == false, nextTotal <= maxStagedTotalBytes else {
      return nil
    }

    return nextTotal
  }

  static func normalizedBasename(_ basename: String) -> String {
    basename.precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }

  func readsPrivateData(in stages: [LoadedStage]) -> Bool {
    stages.contains { stage in
      isPrivate(realpath: stage.record.realpath)
    }
  }

  func isPrivate(realpath: String) -> Bool {
    guard let canonicalRoot = WorkspacePathContainment.canonicalPath(workspaceRoot.path) else {
      return false
    }
    return realpath == canonicalRoot + "/MEMORY.md"
      || realpath == canonicalRoot + "/USER.md"
  }
}

// MARK: - Canonical Encoding

private extension ExecuteCodeTool {
  static func decode<Value: Decodable>(_ type: Value.Type, from arguments: JSONValue) -> Value? {
    guard let data = try? JSONEncoder().encode(arguments) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func canonicalJSON<Value: Encodable>(_ value: Value) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard
      let data = try? encoder.encode(value),
      let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return json
  }

  static func canonicalTarget(language: ExecLanguage, canonicalArgsJSON: String) -> String {
    "code_exec:\(language.rawValue):"
      + String(SHA256Digest.hex(Data(canonicalArgsJSON.utf8)).prefix(16))
  }

  func approvalPresentation(
    raw: RawArguments,
    recorded: RecordedArguments
  ) -> ToolApprovalPresentation {
    let codeBytes = raw.code.utf8.count
    let totalBytes = recorded.stage.reduce(0) { partial, stage in
      partial + stage.bytes
    }
    // The path and realpath are model- and filesystem-derived, so a loaded secret could sit inside
    // one; redact them for the owner-facing preview while the canonical action keeps the true values.
    let stagedSummary =
      recorded.stage.isEmpty
      ? "Staged inputs: none"
      : (["Staged inputs:"]
        + recorded.stage.map { stage in
          "- \(redactor.redact(stage.path)) | \(redactor.redact(stage.realpath)) | \(stage.bytes) B | \(stage.sha256.prefix(16))"
        }).joined(separator: "\n")
    let preview = """
      ```\(recorded.language.rawValue)
      \(redactor.redact(raw.code))
      ```
      \(stagedSummary)
      """

    return ToolApprovalPresentation(
      blastRadius:
        "run \(recorded.language.rawValue) · egress: \(recorded.network ? "yes" : "no") · \(settings.cpus) CPU / \(settings.memoryMiB) MiB · code \(codeBytes) B · \(recorded.stage.count) staged file(s), \(totalBytes) B",
      contentPreview: preview,
      warnings: recorded.network
        ? ["network egress is enabled — this run can send data out"] : []
    )
  }

  func stagedInputsSummary(_ stages: [RecordedStage]) -> String {
    guard stages.isEmpty == false else {
      return "Staged inputs: none"
    }
    // The path and realpath are model- and filesystem-derived, so a loaded secret could sit inside
    // one; redact them for the owner-facing preview while the canonical action keeps the true values.
    var lines = ["Staged inputs:"]
    for stage in stages {
      let path = redactor.redact(stage.path)
      let realpath = redactor.redact(stage.realpath)
      lines.append("- \(path) | \(realpath) | \(stage.bytes) B | \(stage.sha256.prefix(16))")
    }

    return lines.joined(separator: "\n")
  }
}

// MARK: - Resume Revalidation

private extension ExecuteCodeTool {
  func reloadRecordedStages(_ records: [RecordedStage]) -> StageLoadResult {
    guard records.count <= Self.maxStagedFiles else {
      return .failure("The recorded stage count exceeds the approved cap; nothing ran.")
    }

    var recordedTotalBytes = 0
    for record in records {
      guard record.bytes >= 0, record.bytes <= Self.maxStagedFileBytes else {
        return .failure("A recorded staged-file size exceeds the approved cap; nothing ran.")
      }
      let (nextTotal, overflow) = recordedTotalBytes.addingReportingOverflow(record.bytes)
      guard overflow == false, nextTotal <= Self.maxStagedTotalBytes else {
        return .failure("The recorded staged total exceeds the approved cap; nothing ran.")
      }
      recordedTotalBytes = nextTotal
    }

    var loaded: [LoadedStage] = []
    var normalizedNames = Set<String>()
    var totalBytes = 0

    for record in records {
      let liveRealpath: String
      switch WorkspacePathContainment.resolveExisting(
        path: record.path,
        root: workspaceRoot.path
      ) {
      case .refused:
        return .failure("A staged path no longer resolves to its approved target; nothing ran.")
      case .resolved(let resolved):
        liveRealpath = resolved
      }
      guard liveRealpath == record.realpath else {
        return .failure("A staged path no longer resolves to its approved target; nothing ran.")
      }

      let attributes: [FileAttributeKey: Any]
      do {
        attributes = try FileManager.default.attributesOfItem(atPath: liveRealpath)
      } catch {
        return .failure("A staged file became unavailable after approval; nothing ran.")
      }
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber,
        size.intValue == record.bytes,
        size.intValue <= Self.maxStagedFileBytes
      else {
        return .failure("A staged file no longer has its approved size and type; nothing ran.")
      }

      let data: Data
      do {
        guard
          let bounded = try Self.readBoundedFile(
            atPath: liveRealpath,
            maxBytes: Self.maxStagedFileBytes
          )
        else {
          return .failure("A staged file grew past its approved cap; nothing ran.")
        }
        data = bounded
      } catch {
        return .failure("A staged file became unreadable after approval; nothing ran.")
      }
      guard data.count == record.bytes, SHA256Digest.hex(data) == record.sha256 else {
        return .failure("A staged file no longer matches its approved bytes; nothing ran.")
      }
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
      guard overflow == false, nextTotal <= Self.maxStagedTotalBytes else {
        return .failure("Staged files exceed the approved total cap; nothing ran.")
      }
      totalBytes = nextTotal

      let basename = (record.path as NSString).lastPathComponent
      let normalized = Self.normalizedBasename(basename)
      guard normalized.hasPrefix(".clawd-entrypoint.") == false,
        normalizedNames.insert(normalized).inserted
      else {
        return .failure(
          "The staged basename set no longer satisfies the approved layout; nothing ran."
        )
      }

      loaded.append(
        LoadedStage(
          record: record,
          basename: basename,
          bytes: data
        )
      )
    }

    return .success(loaded)
  }
}

// MARK: - Result Mapping

private extension ExecuteCodeTool {
  static let timeoutCopy = "The sandbox exceeded its execution timeout and was killed."
  static let cancellationCopy = "The sandbox execution was cancelled."
  static let memoryCapHint = "The run may have hit its memory cap."

  func map(result: ExecutionResult, readsPrivateData: Bool) -> ToolPayload {
    switch result.terminationReason {
    case .exited(let code):
      let stdout = redactor.redact(result.stdout)
      let stderr = redactor.redact(result.stderr)
      var content = """
        exit \(code)
        --- stdout ---
        \(stdout)
        --- stderr ---
        \(stderr)
        """
      if code == 137 {
        content += "\n" + Self.memoryCapHint
      }
      if result.truncatedRawBytes {
        content += "\n" + Self.rawOutputTruncationNotice
      }
      return ToolPayload(
        content: ToolOutputCap.cap(content),
        status: .ok,
        ingestedUntrusted: true,
        readPrivateData: readsPrivateData
      )
    case .timedOutKilled:
      return errorPayload(Self.timeoutCopy)
    case .cancelled:
      return errorPayload(Self.cancellationCopy)
    case .startFailed(let reason):
      return errorPayload("The sandbox could not start: \(reason)")
    case .unavailable(let reason):
      return errorPayload("The sandbox is unavailable: \(reason)")
    }
  }

  func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(
      content: redactor.redact(reason),
      status: .error,
      ingestedUntrusted: false,
      readPrivateData: false
    )
  }
}
