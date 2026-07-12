import ClawCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public actor ContainerBackend {
  public static let maxRawStreamBytes = 1024 * 1024
  public static let maxControlStreamBytes = 1024 * 1024
  public static let teardownAllowance: Duration = .seconds(20)
  public static let lifecycleCommandTimeout: Duration = .seconds(5)
  public static let ordinaryCommandTimeout: Duration = .seconds(15)
  public static let pullTimeout: Duration = .seconds(120)
  public static let prepareTimeout: Duration = .seconds(300)

  let settings: ExecSandboxSettings
  let stateRoot: URL
  let commands: any ContainerCommandRunning
  let sanitizeReason: @Sendable (String) -> String
  let now: @Sendable () -> ContinuousClock.Instant
  let supportedHost: @Sendable () -> Bool

  var preparedInitImage: String?
  var executionTail: Task<Void, Never>?
  var executionTasks: [UUID: Task<ExecutionResult, Never>] = [:]
  var cleanupTasks: [UUID: Task<Bool, Never>] = [:]
  var shuttingDown = false

  public init(
    settings: ExecSandboxSettings,
    stateRoot: URL,
    commands: any ContainerCommandRunning,
    sanitizeReason: @escaping @Sendable (String) -> String,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.settings = settings
    self.stateRoot = stateRoot
    self.commands = commands
    self.sanitizeReason = sanitizeReason
    self.now = now
    self.supportedHost = Self.defaultSupportedHost
  }

  init(
    settings: ExecSandboxSettings,
    stateRoot: URL,
    commands: any ContainerCommandRunning,
    sanitizeReason: @escaping @Sendable (String) -> String,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    supportedHost: @escaping @Sendable () -> Bool
  ) {
    self.settings = settings
    self.stateRoot = stateRoot
    self.commands = commands
    self.sanitizeReason = sanitizeReason
    self.now = now
    self.supportedHost = supportedHost
  }

  var queuedExecutionCountForTesting: Int { executionTasks.count }

  func runSerializedForTesting(
    operation: @escaping @Sendable () async -> ExecutionResult
  ) async -> ExecutionResult {
    await enqueueExecution(operation: operation)
  }
}

// MARK: - Serialized Execution

private extension ContainerBackend {
  func enqueueExecution(
    operation: @escaping @Sendable () async -> ExecutionResult
  ) async -> ExecutionResult {
    guard !shuttingDown, !Task.isCancelled else { return Self.cancelledResult() }
    let prior = executionTail
    let taskIdentifier = UUID()
    let work = Task<ExecutionResult, Never> {
      await prior?.value
      guard !Task.isCancelled else { return Self.cancelledResult() }
      return await operation()
    }
    executionTasks[taskIdentifier] = work
    executionTail = Task<Void, Never> { _ = await work.value }
    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    executionTasks[taskIdentifier] = nil
    return result
  }

  static func cancelledResult() -> ExecutionResult {
    ExecutionResult(
      terminationReason: .cancelled,
      stdout: "",
      stderr: "",
      truncatedRawBytes: false,
      wallClock: .zero
    )
  }

  nonisolated static func defaultSupportedHost() -> Bool {
    #if os(macOS) && arch(arm64)
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    #else
      false
    #endif
  }
}

enum ScratchWorkspaceError: Error, Equatable {
  case invalidRequest(String)
  case fileSystem(String)
}

struct ScratchWorkspace: Sendable {
  static let maxEntrypointBytes = 16 * 1024
  static let maxInputBytes = 1024 * 1024
  static let maxInputTotalBytes = 4 * 1024 * 1024
  static let maxInputFiles = 16

  let scratchRoot: URL
  let controlRoot: URL
  let directory: URL
  let cidFile: URL

  static func create(
    stateRoot: URL,
    identity: ExecutionIdentity,
    request: ExecutionRequest
  ) throws -> ScratchWorkspace {
    try validate(request)
    let scratchRoot = stateRoot.appending(path: "exec-scratch", directoryHint: .isDirectory)
    let controlRoot = stateRoot.appending(path: "exec-control", directoryHint: .isDirectory)
    try ensurePrivateDirectory(scratchRoot)
    try ensurePrivateDirectory(controlRoot)
    let directory = scratchRoot.appending(path: identity.identifier, directoryHint: .isDirectory)
    guard directory.path.withCString({ mkdir($0, 0o700) }) == 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot create execution scratch")
    }
    let workspace = ScratchWorkspace(
      scratchRoot: scratchRoot,
      controlRoot: controlRoot,
      directory: directory,
      cidFile: controlRoot.appending(path: "\(identity.identifier).cid")
    )
    do {
      try write(request.entrypoint, in: directory)
      for input in request.inputs {
        try write(input, in: directory)
      }
      return workspace
    } catch {
      try? workspace.remove()
      throw error
    }
  }

  func remove() throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: directory.path) {
      try manager.removeItem(at: directory)
    }
    if manager.fileExists(atPath: cidFile.path) {
      try manager.removeItem(at: cidFile)
    }
  }
}

// MARK: - Validation

private extension ScratchWorkspace {
  static func validate(_ request: ExecutionRequest) throws {
    let expectedEntrypoint =
      switch request.language {
      case .python: ".clawd-entrypoint.py"
      case .sh: ".clawd-entrypoint.sh"
      }
    guard
      request.entrypoint.name == expectedEntrypoint,
      request.entrypoint.mode == .readExecute,
      request.entrypoint.bytes.count <= maxEntrypointBytes
    else {
      throw ScratchWorkspaceError.invalidRequest("invalid execution entrypoint")
    }
    guard request.inputs.count <= maxInputFiles else {
      throw ScratchWorkspaceError.invalidRequest("too many staged inputs")
    }
    var normalizedNames = Set<String>()
    var totalBytes = 0
    for input in request.inputs {
      guard input.mode == .readOnly else {
        throw ScratchWorkspaceError.invalidRequest("staged input mode is not read-only")
      }
      guard isBareName(input.name), !isReserved(input.name) else {
        throw ScratchWorkspaceError.invalidRequest("invalid staged input name")
      }
      let normalized = input.name.precomposedStringWithCanonicalMapping.lowercased()
      guard normalizedNames.insert(normalized).inserted else {
        throw ScratchWorkspaceError.invalidRequest("duplicate staged input name")
      }
      guard input.bytes.count <= maxInputBytes else {
        throw ScratchWorkspaceError.invalidRequest("staged input exceeds per-file limit")
      }
      let addition = totalBytes.addingReportingOverflow(input.bytes.count)
      guard !addition.overflow, addition.partialValue <= maxInputTotalBytes else {
        throw ScratchWorkspaceError.invalidRequest("staged inputs exceed total limit")
      }
      totalBytes = addition.partialValue
    }
  }

  static func isBareName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && URL(fileURLWithPath: name).lastPathComponent == name
  }

  static func isReserved(_ name: String) -> Bool {
    name.precomposedStringWithCanonicalMapping.lowercased().hasPrefix(".clawd-entrypoint.")
  }
}

// MARK: - Filesystem

private extension ScratchWorkspace {
  static func ensurePrivateDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(url.path, 0o700) == 0 else {
        throw ScratchWorkspaceError.fileSystem("cannot set private directory mode")
      }
    } catch let error as ScratchWorkspaceError {
      throw error
    } catch {
      throw ScratchWorkspaceError.fileSystem("cannot create private directory")
    }
  }

  static func write(_ file: StagedFile, in directory: URL) throws {
    let destination = directory.appending(path: file.name)
    let descriptor = destination.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(file.mode.rawValue))
    }
    guard descriptor >= 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot create staged copy")
    }
    defer { _ = close(descriptor) }
    guard fchmod(descriptor, mode_t(file.mode.rawValue)) == 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot set staged copy mode")
    }
    try file.bytes.withUnsafeBytes { bytes in
      // An empty Data may expose a nil baseAddress; nothing to write in that case.
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = systemWrite(descriptor, base.advanced(by: offset), bytes.count - offset)
        guard written > 0 else {
          throw ScratchWorkspaceError.fileSystem("cannot write staged copy")
        }
        offset += written
      }
    }
  }

  static func systemWrite(
    _ descriptor: Int32,
    _ bytes: UnsafeRawPointer,
    _ count: Int
  ) -> Int {
    #if canImport(Darwin)
      Darwin.write(descriptor, bytes, count)
    #elseif canImport(Glibc)
      Glibc.write(descriptor, bytes, count)
    #else
      -1
    #endif
  }
}
