import ClawCore
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Bounded dated-file IO. Callers serialize mutations through their shared WorkspaceMutationGate.
public struct FileSystemJournalFiles: JournalFiles {
  private let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func load(day: JournalDay) -> JournalFileSnapshot {
    do {
      let target = try containedTarget(day: day)
      guard let bytes = try readBytes(target: target) else {
        return JournalFileSnapshot(day: day, text: "", outcome: .missing)
      }
      guard let text = String(data: bytes, encoding: .utf8) else {
        return JournalFileSnapshot(day: day, text: "", outcome: .unreadable)
      }
      return JournalFileSnapshot(day: day, text: text, outcome: .present)
    } catch JournalFileError.overCap {
      return JournalFileSnapshot(day: day, text: "", outcome: .overCap)
    } catch {
      return JournalFileSnapshot(day: day, text: "", outcome: .unreadable)
    }
  }

  public func append(day: JournalDay, text: String) throws {
    guard !text.isEmpty else {
      return
    }
    let target = try containedTarget(day: day)
    var bytes = try readBytes(target: target) ?? Data()
    guard String(data: bytes, encoding: .utf8) != nil else {
      throw JournalFileError.unreadable
    }
    let addition = Data(text.utf8)
    guard addition.count <= JournalLimits.dayFileBytes - bytes.count else {
      throw JournalFileError.overCap
    }
    // Preserve the owner's original bytes, including Unicode normalization and line endings.
    bytes.append(addition)
    try replace(bytes: bytes, target: target)
  }

  public func delete(day: JournalDay) throws {
    let target = try containedTarget(day: day)
    guard FileManager.default.fileExists(atPath: target) else {
      return
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: target)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw JournalFileError.deleteFailed
      }
      try FileManager.default.removeItem(atPath: target)
    } catch {
      throw JournalFileError.deleteFailed
    }
  }

  public func recentDays(limit: Int) throws -> [JournalDay] {
    guard limit > 0 else {
      return []
    }
    let resolution = WorkspacePathContainment.resolveForCreation(path: "memory", root: root.path)
    guard case .resolved(let directory) = resolution else {
      throw JournalFileError.pathRefused
    }
    guard FileManager.default.fileExists(atPath: directory) else {
      return []
    }
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch {
      throw JournalFileError.listingFailed
    }
    let days = names.compactMap { name -> JournalDay? in
      guard name.hasSuffix(".md"), let day = JournalDay(isoDate: String(name.dropLast(3))),
            let target = try? containedTarget(day: day),
            let attributes = try? FileManager.default.attributesOfItem(atPath: target),
            attributes[.type] as? FileAttributeType == .typeRegular
      else {
        return nil
      }
      return day
    }
    return Array(days.sorted { $0.isoDate > $1.isoDate }.prefix(limit))
  }
}

// MARK: - Containment and Bounded Reads

private extension FileSystemJournalFiles {
  func containedTarget(day: JournalDay) throws -> String {
    let path = "memory/\(day.isoDate).md"
    let resolution = WorkspacePathContainment.resolveForCreation(path: path, root: root.path)
    guard case .resolved(let target) = resolution else {
      throw JournalFileError.pathRefused
    }
    return target
  }

  func readBytes(target: String) throws -> Data? {
    guard FileManager.default.fileExists(atPath: target) else {
      return nil
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: target)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber
      else {
        throw JournalFileError.unreadable
      }
      guard size.int64Value <= Int64(JournalLimits.dayFileBytes) else {
        throw JournalFileError.overCap
      }
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: target))
      defer { try? handle.close() }
      // The bounded read also catches a file that grew after its metadata check.
      let bytes = try handle.read(upToCount: JournalLimits.dayFileBytes + 1) ?? Data()
      guard bytes.count <= JournalLimits.dayFileBytes else {
        throw JournalFileError.overCap
      }
      return bytes
    } catch let error as JournalFileError {
      throw error
    } catch {
      throw JournalFileError.unreadable
    }
  }
}

// MARK: - Atomic Replacement

private extension FileSystemJournalFiles {
  func replace(bytes: Data, target: String) throws {
    let parent = URL(fileURLWithPath: target).deletingLastPathComponent()
    let temporary = parent.appendingPathComponent(".journal-tmp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      // Set owner-only permissions when the temporary file is created, before writing private bytes.
      guard FileManager.default.createFile(
        atPath: temporary.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
      else {
        throw JournalFileError.writeFailed
      }
      let handle = try FileHandle(forWritingTo: temporary)
      do {
        try handle.write(contentsOf: bytes)
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      guard rename(temporary.path, target) == 0 else {
        throw JournalFileError.writeFailed
      }
    } catch {
      throw JournalFileError.writeFailed
    }
  }
}
