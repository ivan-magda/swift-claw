import Foundation

/// Whether the configured host shell is something the daemon can actually launch.
public enum HostShellAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)

  public var isAvailable: Bool {
    self == .available
  }
}

/// The one answer registration and doctor both read, so a tool that is absent and the row that
/// explains why can never disagree.
public enum HostShellProbe {
  public static func availability(
    shellPath: String,
    fileManager: FileManager = .default
  ) -> HostShellAvailability {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: shellPath, isDirectory: &isDirectory) else {
      return .unavailable(reason: "no file at \(shellPath)")
    }
    guard isDirectory.boolValue == false else {
      return .unavailable(reason: "\(shellPath) is a directory")
    }
    guard fileManager.isExecutableFile(atPath: shellPath) else {
      return .unavailable(reason: "\(shellPath) is not executable")
    }
    return .available
  }
}
