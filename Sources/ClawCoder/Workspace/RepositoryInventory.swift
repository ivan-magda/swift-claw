import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct RepositoryInventory: Sendable, Equatable {
  static let byteLimit = 32 * 1024 * 1024
  static let pathLimit = 10_000
  private let entries: [String: Entry]

  enum Failure: Error { case unavailable }

  fileprivate enum Entry: Sendable, Equatable {
    case file(contents: Data, executable: Bool)
    case symlink(target: Data)
  }

  static func capture(at directory: String, git: CoderGit) async throws -> RepositoryInventory {
    let output = try await git.run(
      ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      at: directory
    )
    guard output.isEmpty || output.last == 0 else {
      throw Failure.unavailable
    }
    let rawPaths = output.split(separator: 0)
    guard rawPaths.count <= pathLimit else {
      throw Failure.unavailable
    }
    let root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else {
      throw Failure.unavailable
    }
    defer { close(root) }
    var entries: [String: Entry] = [:]
    var remaining = byteLimit
    for raw in Set(rawPaths) {
      try Task.checkCancellation()
      guard ContinuousClock.now < git.deadline else {
        throw CoderGitFailure.deadline
      }
      guard let path = String(bytes: raw, encoding: .utf8) else {
        throw Failure.unavailable
      }
      if let entry = try readEntry(path, root: root, remaining: &remaining) {
        entries[path] = entry
      }
    }
    return RepositoryInventory(entries: entries)
  }

  // swiftlint:disable:next discouraged_optional_collection
  func changedPaths(comparedWith baseline: RepositoryInventory) -> [String]? {
    Set(entries.keys).union(baseline.entries.keys).filter { path in
      entries[path] != baseline.entries[path]
    }.sorted()
  }
}

// MARK: - Descriptor-relative file evidence

private extension RepositoryInventory {
  static func readEntry(_ path: String, root: Int32, remaining: inout Int) throws -> Entry? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard
      parts.allSatisfy({ part in
        !part.isEmpty && part != "." && part != ".." && part != ".git"
      })
    else {
      throw Failure.unavailable
    }
    var directory = dup(root)
    guard directory >= 0 else {
      throw Failure.unavailable
    }
    defer { close(directory) }
    for part in parts.dropLast() {
      let child = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard child >= 0 else {
        if errno == ENOENT {
          return nil
        }
        throw Failure.unavailable
      }
      close(directory)
      directory = child
    }
    guard let name = parts.last else {
      throw Failure.unavailable
    }
    var metadata = stat()
    guard fstatat(directory, String(name), &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT {
        return nil
      }
      throw Failure.unavailable
    }
    if metadata.st_mode & S_IFMT == S_IFLNK {
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = readlinkat(directory, String(name), &bytes, bytes.count)
      guard count >= 0, count < bytes.count, count <= remaining else {
        throw Failure.unavailable
      }
      remaining -= count
      return .symlink(target: Data(bytes.prefix(count)))
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw Failure.unavailable
    }
    return try readFile(String(name), directory: directory, remaining: &remaining)
  }

  static func readFile(_ name: String, directory: Int32, remaining: inout Int) throws -> Entry {
    var metadata = stat()
    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else {
      throw Failure.unavailable
    }
    defer { close(file) }
    guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0, metadata.st_size <= remaining
    else {
      throw Failure.unavailable
    }
    let contents = try readContents(file, remaining: &remaining)
    return .file(contents: contents, executable: metadata.st_mode & 0o111 != 0)
  }

  static func readContents(_ file: Int32, remaining: inout Int) throws -> Data {
    var contents = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      try Task.checkCancellation()
      let count = read(file, &buffer, buffer.count)
      if count == 0 {
        return contents
      }
      if count < 0, errno == EINTR {
        continue
      }
      guard count > 0, count <= remaining else {
        throw Failure.unavailable
      }
      remaining -= count
      contents.append(contentsOf: buffer.prefix(count))
    }
  }
}
