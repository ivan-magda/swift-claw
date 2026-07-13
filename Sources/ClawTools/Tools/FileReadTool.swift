import ClawCore
import Foundation

/// Workspace file READ. Containment lives in `WorkspacePathContainment`: the
/// joined path is resolved to its canonical real path (`realpath` — symlinks and `..` fully
/// resolved) and the canonical workspace root must be a path-component prefix of the FINAL
/// target.
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
      ]),
      egressClass: .none,
      riskLevel: .safe
    )
  }

  public var timeout: Duration { .seconds(5) }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    nil  // nothing egresses; containment is enforced inside execute
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    guard
      let path = arguments.objectValue?["path"]?.stringValue,
      path.isEmpty == false
    else {
      return errorPayload("file_read needs a non-empty \"path\" argument.")
    }
    guard let canonicalRoot = WorkspacePathContainment.canonicalPath(workspaceRoot.path) else {
      return errorPayload("The workspace root is unavailable.")
    }
    let canonicalTarget: String
    switch WorkspacePathContainment.resolveExisting(path: path, root: workspaceRoot.path) {
    case .refused(let reason):
      return errorPayload(reason)
    case .resolved(let resolved):
      canonicalTarget = resolved
    }

    guard let data = FileManager.default.contents(atPath: canonicalTarget) else {
      return errorPayload("No file exists at \(path).")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return errorPayload("\(path) is not a UTF-8 text file, so I can't read it.")
    }

    let redacted = redactor.redact(text)
    let readPrivateData = WorkspaceFile.isPrivateData(
      canonicalPath: canonicalTarget,
      canonicalRoot: canonicalRoot
    )

    return ToolPayload(
      content: ToolOutputCap.cap(redacted, maxGraphemes: outputCapGraphemes),
      status: .ok,
      ingestedUntrusted: true,  // a workspace file can be a downloaded artifact
      readPrivateData: readPrivateData
    )
  }

  private func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }
}
