import Foundation

/// A unique on-disk SQLite path under the system temp directory. The random suffix keeps parallel
/// test cases from colliding on the same file; callers own the cleanup `defer`.
public func makeTempDatabasePath(prefix: String) -> String {
  NSTemporaryDirectory() + "\(prefix)-\(UInt64.random(in: 0..<(.max))).sqlite"
}

/// A fresh, unique temp directory keyed by `prefix`, created on disk and returned as a URL — the
/// per-test state root that keeps the secrets suites parallel-safe. Callers own the cleanup `defer`.
public func makeTemporaryRoot(prefix: String) throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

/// The names of a directory's immediate entries, sorted — so a test can assert exactly which
/// artifacts a step left on disk (and, by their absence, which it did not strand).
public func entryNames(in directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}
