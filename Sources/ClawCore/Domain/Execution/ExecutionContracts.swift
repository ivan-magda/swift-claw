import Foundation

public enum ExecLanguage: String, Sendable, Equatable, Codable {
  case python
  case sh
}

extension ExecLanguage {
  /// Namespace reserved for the staged entrypoint file; staged inputs must never claim it.
  public static let reservedEntrypointPrefix = ".clawd-entrypoint."

  /// Staged file name of the script the sandbox executes for this language.
  public var entrypointFileName: String {
    switch self {
    case .python: "\(Self.reservedEntrypointPrefix)py"
    case .sh: "\(Self.reservedEntrypointPrefix)sh"
    }
  }
}

public struct ExecStagingLimits: Sendable, Equatable {
  public let maxCodeBytes: Int
  public let maxStagedFileBytes: Int
  public let maxStagedTotalBytes: Int
  public let maxStagedFiles: Int

  public init(
    maxCodeBytes: Int,
    maxStagedFileBytes: Int,
    maxStagedTotalBytes: Int,
    maxStagedFiles: Int
  ) {
    self.maxCodeBytes = maxCodeBytes
    self.maxStagedFileBytes = maxStagedFileBytes
    self.maxStagedTotalBytes = maxStagedTotalBytes
    self.maxStagedFiles = maxStagedFiles
  }

  public static let standard = ExecStagingLimits(
    maxCodeBytes: 16 * 1024,
    maxStagedFileBytes: 1024 * 1024,
    maxStagedTotalBytes: 4 * 1024 * 1024,
    maxStagedFiles: 16
  )
}

public enum FileMode: UInt16, Sendable, Equatable {
  case readOnly = 0o400
  case readExecute = 0o500
}

public struct StagedFile: Sendable, Equatable {
  public let name: String
  public let bytes: Data
  public let mode: FileMode

  public init(name: String, bytes: Data, mode: FileMode) {
    self.name = name
    self.bytes = bytes
    self.mode = mode
  }
}

public struct ExecutionRequest: Sendable, Equatable {
  public let language: ExecLanguage
  public let entrypoint: StagedFile
  public let inputs: [StagedFile]
  public let network: Bool
  public let timeout: Duration

  public init(
    language: ExecLanguage,
    entrypoint: StagedFile,
    inputs: [StagedFile],
    network: Bool,
    timeout: Duration
  ) {
    self.language = language
    self.entrypoint = entrypoint
    self.inputs = inputs
    self.network = network
    self.timeout = timeout
  }
}

public enum ExecTermination: Sendable, Equatable {
  case exited(code: Int32)
  case timedOutKilled
  case cancelled
  case startFailed(reason: String)
  case unavailable(reason: String)
}

public struct ExecutionResult: Sendable, Equatable {
  public let terminationReason: ExecTermination
  public let stdout: String
  public let stderr: String
  public let truncatedRawBytes: Bool

  public init(
    terminationReason: ExecTermination,
    stdout: String,
    stderr: String,
    truncatedRawBytes: Bool
  ) {
    self.terminationReason = terminationReason
    self.stdout = stdout
    self.stderr = stderr
    self.truncatedRawBytes = truncatedRawBytes
  }
}

public enum BackendAvailability: Sendable, Equatable {
  case available(engineVersion: String)
  case unavailable(reason: String)
}

public struct SandboxHealth: Sendable, Equatable {
  public let available: Bool
  public let osOK: Bool
  public let engineVersion: String?
  public let versionOK: Bool
  public let imageDigestOK: Bool
  public let capsEmpty: Bool
  public let netIsolated: Bool
  public let capsMatch: Bool
  public let reaperOK: Bool
  public let rootfsRO: Bool
  public let stagingRO: Bool
  public let interpretersOK: Bool
  public let lastError: String?

  public init(
    available: Bool,
    osOK: Bool,
    engineVersion: String?,
    versionOK: Bool,
    imageDigestOK: Bool,
    capsEmpty: Bool,
    netIsolated: Bool,
    capsMatch: Bool,
    reaperOK: Bool,
    rootfsRO: Bool,
    stagingRO: Bool,
    interpretersOK: Bool,
    lastError: String?
  ) {
    self.available = available
    self.osOK = osOK
    self.engineVersion = engineVersion
    self.versionOK = versionOK
    self.imageDigestOK = imageDigestOK
    self.capsEmpty = capsEmpty
    self.netIsolated = netIsolated
    self.capsMatch = capsMatch
    self.reaperOK = reaperOK
    self.rootfsRO = rootfsRO
    self.stagingRO = stagingRO
    self.interpretersOK = interpretersOK
    self.lastError = lastError
  }

  public var isReady: Bool {
    available && osOK && versionOK && imageDigestOK && capsEmpty && netIsolated && capsMatch
      && reaperOK && rootfsRO && stagingRO && interpretersOK && lastError == nil
  }

  public static let passingForTests = SandboxHealth(
    available: true,
    osOK: true,
    engineVersion: "1.1.0",
    versionOK: true,
    imageDigestOK: true,
    capsEmpty: true,
    netIsolated: true,
    capsMatch: true,
    reaperOK: true,
    rootfsRO: true,
    stagingRO: true,
    interpretersOK: true,
    lastError: nil
  )
}

public protocol ExecutionBackend: Sendable {
  func probe() async -> BackendAvailability
  func run(_ request: ExecutionRequest) async -> ExecutionResult
}

public protocol SandboxMaintenance: Sendable {
  func prepare() async -> SandboxHealth
  func shutdown() async
  func isAdmitting() async -> Bool
}
