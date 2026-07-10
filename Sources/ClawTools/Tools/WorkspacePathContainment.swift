import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Shared realpath-based workspace containment, extracted from `FileReadTool` and extended for
/// file CREATION so `file_write` resolves the same invariant at gate time. Containment is
/// path-COMPONENT prefix, never string prefix.
public enum WorkspacePathContainment {
  public enum Resolution: Sendable, Equatable {
    case resolved(String)
    case refused(reason: String)
  }

  /// Resolves a workspace-relative path that must already exist: `realpath(3)` the joined path
  /// (symlinks and `..` fully resolved), then assert the canonical root contains the final
  /// target. Refusal copy matches `FileReadTool`'s pre-extraction strings exactly.
  public static func resolveExisting(path: String, root: String) -> Resolution {
    if let reason = shapeRefusal(path) {
      return .refused(reason: reason)
    }
    guard let canonicalRoot = canonicalPath(root) else {
      return .refused(reason: "The workspace root is unavailable.")
    }

    let joined = URL(fileURLWithPath: root).appendingPathComponent(path).path
    guard let target = canonicalPath(joined) else {
      return .refused(reason: "No file exists at \(path).")
    }
    guard isContained(target: target, root: canonicalRoot) else {
      return .refused(reason: "That path resolves outside the workspace, so I can't read it.")
    }

    return .resolved(target)
  }

  /// Creation mode: canonicalize the deepest EXISTING ancestor (asserting containment at
  /// every resolved step — a mid-path symlink may jump anywhere), then validate each remaining
  /// to-be-created component. `.`/`..` are refused outright for writes: new components cannot be
  /// realpath-resolved, so lexical dot-traversal is never trusted.
  public static func resolveForCreation(path: String, root: String) -> Resolution {
    if let reason = shapeRefusal(path) {
      return .refused(reason: reason)
    }
    guard let canonicalRoot = canonicalPath(root) else {
      return .refused(reason: "The workspace root is unavailable.")
    }

    let components = path.split(separator: "/").map(String.init)
    guard components.isEmpty == false else {
      return .refused(reason: "The path is empty.")
    }
    guard components.contains(where: { $0 == ".." || $0 == "." }) == false else {
      return .refused(
        reason: "Paths with \".\" or \"..\" components can't be written; name the target directly."
      )
    }

    var resolvedPrefix = canonicalRoot
    var index = 0
    while index < components.count {
      let candidate = resolvedPrefix + "/" + components[index]
      guard let resolvedCandidate = canonicalPath(candidate) else {
        break  // first non-existing component — everything from here is to-be-created
      }

      guard isContained(target: resolvedCandidate, root: canonicalRoot) else {
        return .refused(
          reason: "That path resolves outside the workspace, so I can't write it."
        )
      }

      resolvedPrefix = resolvedCandidate
      index += 1
    }

    if index < components.count, entryExists(atPath: resolvedPrefix + "/" + components[index]) {
      // realpath failed but lstat sees SOMETHING: a dangling symlink — creating "through" it
      // would follow the link to an unvetted destination.
      return .refused(reason: "That path is a broken symlink, so I can't write through it.")
    }

    let remainder = components[index...].joined(separator: "/")
    let resolved = remainder.isEmpty ? resolvedPrefix : resolvedPrefix + "/" + remainder
    guard isContained(target: resolved, root: canonicalRoot) else {
      return .refused(reason: "That path resolves outside the workspace, so I can't write it.")
    }

    return .resolved(resolved)
  }

  /// `realpath(3)`: nil when the path (or any component) does not exist.
  public static func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else {
      return nil
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Path-COMPONENT prefix, not string prefix — `/a/bc` must not count as inside `/a/b`.
  public static func isContained(target: String, root: String) -> Bool {
    target == root || target.hasPrefix(root + "/")
  }
}

// MARK: - Shape Validation

private extension WorkspacePathContainment {
  static func shapeRefusal(_ path: String) -> String? {
    guard path.isEmpty == false else {
      return "The path is empty."
    }
    guard path.hasPrefix("/") == false else {
      return "Absolute paths are not allowed; use a workspace-relative path."
    }
    return nil
  }

  /// `lstat(2)` — sees the link ITSELF, so a dangling symlink still "exists" here.
  static func entryExists(atPath path: String) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0
  }
}
