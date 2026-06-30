import Foundation

/// Creates a unique, empty temporary workspace root. The caller removes it in a `defer`.
func makeTemporaryRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("claw-workspace-tests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

/// Writes a UTF-8 file at `relativePath` under `root`, creating intermediate directories.
func writeFile(atRelativePath relativePath: String, content: String, under root: URL) throws {
  let fileURL = root.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(
    at: fileURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try content.write(to: fileURL, atomically: true, encoding: .utf8)
}

/// Writes raw bytes at `relativePath` under `root` (used to create an invalid-UTF-8 file).
func writeRawFile(atRelativePath relativePath: String, bytes: [UInt8], under root: URL) throws {
  let fileURL = root.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(
    at: fileURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(bytes).write(to: fileURL)
}

/// Writes `skills/<name>/SKILL.md` under `root`, creating intermediate directories.
func writeSkill(named name: String, manifest: String, under root: URL) throws {
  try writeFile(atRelativePath: "skills/\(name)/SKILL.md", content: manifest, under: root)
}
