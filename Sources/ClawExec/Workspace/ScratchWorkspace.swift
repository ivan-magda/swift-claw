import ClawCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum ScratchWorkspaceError: Error, Equatable {
  case invalidRequest(String)
  case fileSystem(String)
}

struct ScratchWorkspace: Sendable {
  static let scratchRootName = "exec-scratch"
  static let controlRootName = "exec-control"

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

    let scratchRoot = stateRoot.appending(path: scratchRootName, directoryHint: .isDirectory)
    let controlRoot = stateRoot.appending(path: controlRootName, directoryHint: .isDirectory)
    let directory = scratchRoot.appending(path: identity.identifier, directoryHint: .isDirectory)
    // This directory becomes the source of a `--mount type=bind,source=…` directive, whose
    // comma/equals grammar has no escape syntax in apple/container 1.1.0; a delimiter in the
    // path would be parsed as extra directive fields, so refuse it before creating anything.
    guard !directory.path.contains(","), !directory.path.contains("=") else {
      throw ScratchWorkspaceError.invalidRequest(
        "state root path contains characters that cannot cross a mount directive"
      )
    }

    try ensurePrivateDirectory(scratchRoot)
    try ensurePrivateDirectory(controlRoot)

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
    let expectedEntrypoint = ExecEntrypoint.fileName(for: request.language)

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
    !name.isEmpty
      && name != "."
      && name != ".."
      && !name.contains("/")
      && !name.contains("\\")
      && URL(fileURLWithPath: name).lastPathComponent == name
  }

  static func isReserved(_ name: String) -> Bool {
    name.precomposedStringWithCanonicalMapping.lowercased().hasPrefix(ExecEntrypoint.reservedPrefix)
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
    defer {
      _ = close(descriptor)
    }

    guard fchmod(descriptor, mode_t(file.mode.rawValue)) == 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot set staged copy mode")
    }

    try file.bytes.withUnsafeBytes { bytes in
      // An empty Data may expose a nil baseAddress; nothing to write in that case.
      guard let base = bytes.baseAddress else {
        return
      }

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
