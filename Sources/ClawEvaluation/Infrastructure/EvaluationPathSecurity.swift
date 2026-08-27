import ClawCore
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

enum EvaluationPathSecurity {
  static func isStrictlyContained(_ candidate: URL, under root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return candidatePath != rootPath
      && WorkspacePathContainment.isContained(target: candidatePath, root: rootPath)
  }

  static func isContainedOrEqual(_ candidate: URL, under root: URL) -> Bool {
    WorkspacePathContainment.isContained(
      target: candidate.standardizedFileURL.path,
      root: root.standardizedFileURL.path
    )
  }

  static func relativePath(of candidate: URL, under root: URL) -> String? {
    let candidate = candidate.standardizedFileURL
    let root = root.standardizedFileURL
    guard isStrictlyContained(candidate, under: root) else { return nil }
    return candidate.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
  }

  package static func ensurePrivateDirectory(at directory: URL) throws {
    try rejectSymlinkComponents(in: [directory])
    try PrivateDirectory.ensure(at: directory)
    try rejectSymlinkComponents(in: [directory])
  }

  package static func rejectSymlinkComponents(in paths: [URL]) throws {
    for path in paths {
      if let dotComponent = path.pathComponents.first(where: { $0 == "." || $0 == ".." }) {
        throw EvaluationPathSecurityError.dotPathComponent(dotComponent)
      }
      try rejectSymlinkComponents(of: path.standardizedFileURL)
    }
  }

  static func requireRegularSingleLinkFile(at file: URL) throws {
    let (descriptor, _) = try openRegularSingleLinkFile(at: file)
    guard close(descriptor) == 0 else {
      throw EvaluationPathSecurityError.unavailable(file.lastPathComponent)
    }
  }

  static func secureCreatedRegularSingleLinkFile(
    descriptor: Int32,
    at file: URL,
    permissions: mode_t
  ) throws {
    guard fchmod(descriptor, permissions) == 0 else {
      throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
    }
    var opened = stat()
    guard
      fstat(descriptor, &opened) == 0,
      (opened.st_mode & mode_t(0o777)) == permissions
    else {
      throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
    }
    try validateOpenedFile(descriptor, at: file, matching: opened)
  }

  static func appendAndSynchronize(
    _ data: Data,
    toRegularSingleLinkFileAt file: URL
  ) throws {
    let (descriptor, opened) = try openRegularSingleLinkFile(
      at: file,
      accessFlags: O_WRONLY | O_APPEND | O_NONBLOCK
    )
    defer { close(descriptor) }
    var offset = 0
    try data.withUnsafeBytes { buffer in
      guard data.isEmpty || buffer.baseAddress != nil else {
        throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
      }
      while offset < data.count {
        let count = write(
          descriptor,
          buffer.baseAddress?.advanced(by: offset),
          data.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
        }
        offset += count
      }
    }
    guard fsync(descriptor) == 0 else {
      throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
    }
    try validateOpenedFile(
      descriptor,
      at: file,
      matching: opened,
      requireSameSize: false
    )
  }

  static func readRegularSingleLinkFile(
    at file: URL,
    expectedByteCount: Int? = nil,
    maximumByteCount: Int = 16 * 1_024 * 1_024
  ) throws -> Data {
    let (descriptor, opened) = try openRegularSingleLinkFile(at: file)
    defer { close(descriptor) }
    guard
      opened.st_size >= 0,
      opened.st_size <= off_t(Int.max),
      expectedByteCount.map({ $0 >= 0 && opened.st_size == off_t($0) })
        ?? (maximumByteCount >= 0 && opened.st_size <= off_t(maximumByteCount))
    else {
      throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
    }
    let byteCount = Int(opened.st_size)
    var data = Data(count: byteCount)
    var offset = 0
    try data.withUnsafeMutableBytes { buffer in
      guard byteCount == 0 || buffer.baseAddress != nil else {
        throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
      }
      while offset < byteCount {
        let count = read(descriptor, buffer.baseAddress?.advanced(by: offset), byteCount - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
        }
        offset += count
      }
    }
    var trailingByte: UInt8 = 0
    let trailingCount = read(descriptor, &trailingByte, 1)
    guard trailingCount == 0 else {
      throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
    }
    try validateOpenedFile(descriptor, at: file, matching: opened)
    return data
  }
}

private extension EvaluationPathSecurity {
  static func openRegularSingleLinkFile(
    at file: URL,
    accessFlags: Int32 = O_RDONLY | O_NONBLOCK
  ) throws -> (Int32, stat) {
    try rejectSymlinkComponents(in: [file])
    let descriptor = open(file.path, accessFlags | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw EvaluationPathSecurityError.unavailable(file.lastPathComponent)
    }
    do {
      var opened = stat()
      guard fstat(descriptor, &opened) == 0 else {
        throw EvaluationPathSecurityError.unavailable(file.lastPathComponent)
      }
      try validateOpenedFile(descriptor, at: file, matching: opened)
      return (descriptor, opened)
    } catch {
      close(descriptor)
      throw error
    }
  }

  static func validateOpenedFile(
    _ descriptor: Int32,
    at file: URL,
    matching original: stat,
    requireSameSize: Bool = true
  ) throws {
    var opened = stat()
    var entry = stat()
    guard
      fstat(descriptor, &opened) == 0,
      lstat(file.path, &entry) == 0,
      (opened.st_mode & S_IFMT) == S_IFREG,
      opened.st_nlink == 1,
      opened.st_uid == getuid(),
      (entry.st_mode & S_IFMT) == S_IFREG,
      entry.st_nlink == 1,
      entry.st_uid == getuid(),
      opened.st_dev == entry.st_dev,
      opened.st_ino == entry.st_ino,
      opened.st_dev == original.st_dev,
      opened.st_ino == original.st_ino,
      requireSameSize == false || opened.st_size == original.st_size
    else {
      throw EvaluationPathSecurityError.insecureFile(file.lastPathComponent)
    }
  }

  static func rejectSymlinkComponents(of path: URL) throws {
    let boundary = inspectionBoundary(for: path)
    var candidate = boundary
    let boundaryComponents = boundary.pathComponents
    let pathComponents = path.pathComponents

    guard pathComponents.starts(with: boundaryComponents) else {
      throw EvaluationPathSecurityError.unavailable(path.lastPathComponent)
    }

    if boundary.path != "/" {
      try rejectSymlink(at: boundary)
    }
    for component in pathComponents.dropFirst(boundaryComponents.count) {
      candidate.appendPathComponent(component)
      try rejectSymlink(at: candidate)
    }
  }

  static func inspectionBoundary(for path: URL) -> URL {
    let temporary = FileManager.default.temporaryDirectory
    let canonicalTemporary = WorkspacePathContainment.canonicalPath(temporary.path).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let candidates =
      [temporary.standardizedFileURL, temporary.resolvingSymlinksInPath()]
      + [canonicalTemporary].compactMap { $0 }
    return candidates.first { candidate in
      WorkspacePathContainment.isContained(target: path.path, root: candidate.path)
    } ?? URL(fileURLWithPath: "/", isDirectory: true)
  }

  static func rejectSymlink(at candidate: URL) throws {
    var status = stat()
    if lstat(candidate.path, &status) != 0 {
      if errno == ENOENT { return }
      throw EvaluationPathSecurityError.unavailable(candidate.lastPathComponent)
    }
    guard (status.st_mode & S_IFMT) != S_IFLNK else {
      throw EvaluationPathSecurityError.symlinkedComponent(candidate.lastPathComponent)
    }
  }
}

enum EvaluationPathSecurityError: Error, Sendable, Equatable {
  case dotPathComponent(String)
  case symlinkedComponent(String)
  case insecureFile(String)
  case unavailable(String)
}

struct EvaluationManifestBoundArtifact: Sendable {
  let url: URL
  let data: Data
}

enum EvaluationManifestBoundArtifactReader {
  static func read(
    _ artifact: EvaluationManifestArtifact,
    repositoryRoot: URL
  ) throws -> EvaluationManifestBoundArtifact {
    try read(
      relativePath: artifact.path,
      expectedByteCount: artifact.bytes,
      expectedSHA256: artifact.sha256,
      repositoryRoot: repositoryRoot
    )
  }

  static func read(
    _ artifact: EvaluationManifestProtectedArtifact,
    repositoryRoot: URL
  ) throws -> EvaluationManifestBoundArtifact {
    try read(
      relativePath: artifact.path,
      expectedByteCount: artifact.bytes,
      expectedSHA256: artifact.sha256,
      repositoryRoot: repositoryRoot
    )
  }

  static func resolve(relativePath: String, repositoryRoot: URL) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      relativePath.isEmpty == false,
      relativePath.hasPrefix("/") == false,
      components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." })
    else { throw EvaluationManifestBoundArtifactError.invalidRelativePath(relativePath) }

    let root = repositoryRoot.standardizedFileURL
    let raw = root.appendingPathComponent(relativePath)
    let resolved = raw.standardizedFileURL
    guard EvaluationPathSecurity.isStrictlyContained(resolved, under: root) else {
      throw EvaluationManifestBoundArtifactError.invalidRelativePath(relativePath)
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [root, raw])
    return resolved
  }

  static func read(
    relativePath: String,
    expectedByteCount: Int,
    expectedSHA256: String,
    repositoryRoot: URL
  ) throws -> EvaluationManifestBoundArtifact {
    do {
      let resolved = try resolve(relativePath: relativePath, repositoryRoot: repositoryRoot)
      let data = try EvaluationPathSecurity.readRegularSingleLinkFile(
        at: resolved,
        expectedByteCount: expectedByteCount
      )
      guard SHA256Digest.hex(data) == expectedSHA256 else {
        throw EvaluationManifestBoundArtifactError.changed(relativePath)
      }
      return EvaluationManifestBoundArtifact(url: resolved, data: data)
    } catch let error as EvaluationManifestBoundArtifactError {
      throw error
    } catch {
      throw EvaluationManifestBoundArtifactError.changed(relativePath)
    }
  }
}

enum EvaluationManifestBoundArtifactError: Error, Sendable, Equatable {
  case invalidRelativePath(String)
  case changed(String)
}
