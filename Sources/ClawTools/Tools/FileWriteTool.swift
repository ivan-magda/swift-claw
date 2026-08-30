import ClawCore
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Workspace file WRITE — the first ask-tier tool: every call suspends the run to a durable
/// approval, and `execute` runs only on the approval waiter with the RECORDED args —
/// re-validated against the live filesystem at execution time, never through the dispatcher's
/// abandon-on-timeout race. The write is atomic: a temp file in the target's own directory +
/// `rename(2)`, so a crash in any window leaves the previous file intact. Privileged files
/// (SOUL/AGENTS/USER/MEMORY .md) are writable in a DM — the prompt banner flags them; refusing
/// them in code was explicitly rejected. A group topic has no banner and no single owner, so the
/// gate refuses those names there instead.
public struct FileWriteTool: Tool {
  /// Refuse absurd payloads before they ever reach an approval prompt. 256 KiB covers any sane
  /// note/config write; a named constant so tests assert the code's own number.
  public static let maxContentBytes = 256 * 1024
  private let workspaceRoot: URL
  private let redactor: SecretRedactor

  public init(workspaceRoot: URL, redactor: SecretRedactor) {
    self.workspaceRoot = workspaceRoot
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "file_write",
      description: """
        Write a UTF-8 text file inside the workspace (owner approval required). The path is \
        relative to the workspace root; set overwrite to true to replace an existing file.
        """,
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "description": .string("Workspace-relative file path, e.g. notes/plan.md"),
          ]),
          "content": .object([
            "type": .string("string"),
            "description": .string("The full file content to write."),
          ]),
          "overwrite": .object([
            "type": .string("boolean"),
            "description": .string("Must be true to replace an existing file; defaults to false."),
          ]),
        ]),
        "required": .array([.string("path"), .string("content")]),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .ask
    )
  }

  public var timeout: Duration { .seconds(10) }

  /// Gate-time resolution: the approval binds to the fully-resolved contained path.
  /// Overwrite policy and the size cap refuse HERE — a doomed write must never park an approval.
  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    guard
      let path = arguments.objectValue?["path"]?.stringValue,
      path.isEmpty == false
    else {
      return .refused(reason: "file_write needs a non-empty \"path\" argument.")
    }

    guard let content = arguments.objectValue?["content"]?.stringValue else {
      return .refused(reason: "file_write needs a \"content\" argument.")
    }

    guard content.utf8.count <= Self.maxContentBytes else {
      return .refused(
        reason: """
          That write is \(ByteCount.text(content.utf8.count)) — the cap is \
          \(ByteCount.text(Self.maxContentBytes)).
          """
      )
    }

    switch WorkspacePathContainment.resolveForCreation(path: path, root: workspaceRoot.path) {
    case .refused(let reason):
      return .refused(reason: reason)
    case .resolved(let target):
      var isDirectory = ObjCBool(false)
      let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)

      if exists, isDirectory.boolValue {
        return .refused(reason: "\(path) is a directory, so I can't write a file there.")
      }

      if exists, overwriteFlag(arguments) == false {
        return .refused(reason: "\(path) already exists; pass overwrite: true to replace it.")
      }

      if exists == false, overwriteFlag(arguments) {
        // The flag must match the approved mode: the prompt would say "create", but the recorded
        // overwrite:true would take the replacing rename(2) branch at execution — a file that
        // appeared during the approval window would be clobbered under a create-shaped approval.
        return .refused(reason: "\(path) does not exist; drop overwrite: true to create it.")
      }

      return .resolved(target)
    }
  }

  public func approvalPresentation(
    arguments: JSONValue,
    canonicalTarget: String
  ) -> ToolApprovalPresentation {
    let content = arguments.objectValue?["content"]?.stringValue ?? ""
    let exists = FileManager.default.fileExists(atPath: canonicalTarget)
    return ToolApprovalPresentation(
      blastRadius: "\(exists ? "overwrite" : "create"), \(ByteCount.text(content.utf8.count))",
      contentPreview: ToolOutputCap.cap(
        redactor.redact(content),
        maxGraphemes: ToolOutputCap.approvalPreviewGraphemes
      ),
      warnings: []
    )
  }

  /// Runs ONLY on the approval waiter with the RECORDED args. The approval may be up to an hour
  /// stale, so this re-validates before touching the disk: the path must re-resolve to the
  /// exact canonical target the owner approved, and a create-approved write must still be a
  /// create at commit time.
  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    guard let approvedTarget = canonicalTarget else {
      return errorPayload("file_write was dispatched without a gate-resolved target.")
    }

    guard
      let path = arguments.objectValue?["path"]?.stringValue,
      let content = arguments.objectValue?["content"]?.stringValue
    else {
      return errorPayload("file_write needs \"path\" and \"content\" arguments.")
    }

    // Re-resolve NOW: if a component was retargeted since approval (symlink swap, replaced
    // directory), the resolution drifts from the approved target — fail closed, write nothing.
    guard
      case .resolved(let target) = WorkspacePathContainment.resolveForCreation(
        path: path,
        root: workspaceRoot.path
      ),
      target == approvedTarget
    else {
      return errorPayload(
        "The approved path no longer resolves to the approved target; nothing was written."
      )
    }

    let overwriting = overwriteFlag(arguments)
    do {
      try FileManager.default.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
      )

      let tempPath = try Self.stageTemporary(content: Data(content.utf8), target: target)

      if overwriting {
        try Self.commitRename(tempPath: tempPath, target: target)
      } else {
        try Self.commitCreate(tempPath: tempPath, target: target)
      }
    } catch is CreateCollision {
      return errorPayload(
        "\(path) was created while the approval was pending; nothing was overwritten."
      )
    } catch let failure as RenameFailed {
      // The tool has no logger, so the errno rides the observation — a bare number leaks no path
      // beyond the one already in the copy, and it is the only diagnostic the syscall left behind.
      return errorPayload(
        "The write failed (errno \(failure.code)); the previous file, if any, is untouched."
      )
    } catch {
      // Cocoa errors (staging/createDirectory) can embed temp paths in their descriptions, so the
      // copy stays generic here.
      return errorPayload("The write failed; the previous file, if any, is untouched.")
    }

    return ToolPayload(
      content: """
        Wrote \(ByteCount.text(content.utf8.count)) to \(target) \
        (\(overwriting ? "overwritten" : "created")).
        """,
      status: .ok,
      ingestedUntrusted: false
    )
  }
}

// MARK: - Atomic Write Steps

private extension FileWriteTool {
  struct RenameFailed: Error {
    let code: Int32
  }

  /// The target appeared between approval and execution of a CREATE-approved write: the owner
  /// approved "create", so replacing is off the table — fail closed.
  struct CreateCollision: Error {}

  static func stageTemporary(content: Data, target: String) throws -> String {
    let parent = (target as NSString).deletingLastPathComponent
    let leaf = (target as NSString).lastPathComponent
    let tempPath = parent + "/." + leaf + ".claw-tmp-" + UUID().uuidString
    try content.write(to: URL(fileURLWithPath: tempPath))
    return tempPath
  }

  static func commitRename(tempPath: String, target: String) throws {
    guard rename(tempPath, target) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(atPath: tempPath)
      throw RenameFailed(code: code)
    }
  }

  static func commitCreate(tempPath: String, target: String) throws {
    guard link(tempPath, target) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(atPath: tempPath)
      guard code == EEXIST else {
        throw RenameFailed(code: code)
      }
      throw CreateCollision()
    }
    _ = unlink(tempPath)
  }
}

// MARK: - Argument Helpers

private extension FileWriteTool {
  func overwriteFlag(_ arguments: JSONValue) -> Bool {
    guard case .bool(let flag) = arguments.objectValue?["overwrite"] ?? .null else {
      return false  // fail closed: an absent/mistyped flag never overwrites
    }
    return flag
  }

  func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }
}

// MARK: - Byte Formatting

/// Owner-facing byte counts for the approval blast radius ("340 B", "1.2 KB").
enum ByteCount {
  static func text(_ bytes: Int) -> String {
    guard bytes >= 1024 else {
      return "\(bytes) B"
    }
    return String(format: "%.1f KB", Double(bytes) / 1024.0)
  }
}
