import ClawCore
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Workspace file READ (§7.1). Containment (FR-T4): resolve the joined path to its canonical
/// real path (`realpath` — symlinks and `..` fully resolved) and assert the canonical workspace
/// root is a path-component prefix of the FINAL target.
public struct FileReadTool: Tool {
  private let workspaceRoot: URL
  private let redactor: SecretRedactor
  private let outputCapGraphemes: Int

  public init(
    workspaceRoot: URL,
    redactor: SecretRedactor,
    outputCapGraphemes: Int = ToolOutputCap.maxGraphemes
  ) {
    self.workspaceRoot = workspaceRoot
    self.redactor = redactor
    self.outputCapGraphemes = outputCapGraphemes
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "file_read",
      description:
        "Read a UTF-8 text file from the workspace. The path is relative to the workspace root.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "description": .string("Workspace-relative file path, e.g. notes/plan.md"),
          ])
        ]),
        "required": .array([.string("path")]),
      ])
    )
  }

  public var timeout: Duration { .seconds(5) }

  public func execute(arguments: JSONValue) async -> ToolPayload {
    guard
      let path = arguments.objectValue?["path"]?.stringValue,
      path.isEmpty == false
    else {
      return errorPayload("file_read needs a non-empty \"path\" argument.")
    }
    guard path.hasPrefix("/") == false else {
      return errorPayload("Absolute paths are not allowed; use a workspace-relative path.")
    }

    guard let canonicalRoot = Self.canonicalPath(workspaceRoot.path) else {
      return errorPayload("The workspace root is unavailable.")
    }
    let joined = workspaceRoot.appendingPathComponent(path).path
    guard let canonicalTarget = Self.canonicalPath(joined) else {
      return errorPayload("No file exists at \(path).")
    }
    guard Self.isContained(target: canonicalTarget, root: canonicalRoot) else {
      return errorPayload("That path resolves outside the workspace, so I can't read it.")
    }

    guard let data = FileManager.default.contents(atPath: canonicalTarget) else {
      return errorPayload("No file exists at \(path).")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return errorPayload("\(path) is not a UTF-8 text file, so I can't read it.")
    }

    let redacted = redactor.redact(text)
    let readPrivateData =
      canonicalTarget == canonicalRoot + "/MEMORY.md"
      || canonicalTarget == canonicalRoot + "/USER.md"

    return ToolPayload(
      content: ToolOutputCap.cap(redacted, maxGraphemes: outputCapGraphemes),
      status: .ok,
      ingestedUntrusted: true,  // a workspace file can be a downloaded artifact (FR-O3)
      readPrivateData: readPrivateData
    )
  }

  // MARK: - Load-bearing

  /// `realpath(3)`: nil when the path (or any component) does not exist.
  private static func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else {
      return nil
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Path-COMPONENT prefix, not string prefix — `/a/bc` must not count as inside `/a/b`.
  private static func isContained(target: String, root: String) -> Bool {
    target == root || target.hasPrefix(root + "/")
  }

  private func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }
}
