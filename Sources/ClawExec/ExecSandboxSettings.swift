import ClawCore
import Foundation

public struct ExecSandboxSettings: Sendable, Equatable {
  public static let minimumContainerVersion = SemanticVersion(1, 0, 0)

  public static let pythonInterpreter = "/usr/bin/python"
  public static let shellInterpreter = "/bin/sh"
  public static let platform = "linux/arm64"

  public let workloadImage: PinnedImageReference
  public let memoryMiB: Int
  public let cpus: Int

  public init(workloadImage: PinnedImageReference, memoryMiB: Int, cpus: Int) {
    self.workloadImage = workloadImage
    self.memoryMiB = memoryMiB
    self.cpus = cpus
  }
}

public struct SemanticVersion: Sendable, Equatable, Comparable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init?(_ text: String) {
    let components = text.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else {
      return nil
    }

    let isValid = components.allSatisfy { component in
      !component.isEmpty
        && component.utf8.allSatisfy { byte in
          byte >= 0x30 && byte <= 0x39
        }
    }
    guard isValid else {
      return nil
    }

    guard
      let major = Int(components[0]),
      let minor = Int(components[1]),
      let patch = Int(components[2])
    else {
      return nil
    }

    self.init(major, minor, patch)
  }

  public init(_ major: Int, _ minor: Int, _ patch: Int) {
    precondition(major >= 0 && minor >= 0 && patch >= 0)
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }

    if lhs.minor != rhs.minor {
      return lhs.minor < rhs.minor
    }

    return lhs.patch < rhs.patch
  }
}

struct ExecutionIdentity: Sendable, Equatable {
  static let namePrefix = "clawd-exec-"
  static let ownershipLabelKey = "clawd.exec"
  static let ownershipLabelValue = "1"
  static let ownershipLabelArgument = "\(ownershipLabelKey)=\(ownershipLabelValue)"

  let uuid: UUID

  init(uuid: UUID = UUID()) {
    self.uuid = uuid
  }

  var identifier: String {
    uuid.uuidString.lowercased()
  }

  var name: String {
    "\(Self.namePrefix)\(identifier)"
  }
}

/// Guest-side view of the reserved entrypoint namespace: the staged file names come from
/// `ExecLanguage` in ClawCore; only the bind-mounted work directory layout is sandbox knowledge.
enum ExecEntrypoint {
  static let reservedPrefix = ExecLanguage.reservedEntrypointPrefix
  static let guestWorkDirectory = "/work"

  static func fileName(for language: ExecLanguage) -> String {
    language.entrypointFileName
  }

  static func guestPath(for language: ExecLanguage) -> String {
    "\(guestWorkDirectory)/\(fileName(for: language))"
  }
}
