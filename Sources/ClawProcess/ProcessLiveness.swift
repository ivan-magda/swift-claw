import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Whether a process or a process group can still run.
///
/// `kill(pid, 0)` answers "does this pid exist", which is not the same question: a terminated
/// process lingers as a zombie until its parent reaps it, and an orphan's parent is whatever init
/// adopted it. Under a container PID 1 that never calls `wait` — the shape both our Docker deploy
/// and CI's job container use — that reap never comes, so the pid answers `kill(pid, 0) == 0`
/// forever. Code that waits for a terminated descendant to "disappear" would wait for good.
public enum ProcessLiveness {
  /// False once the process has terminated, a not-yet-reaped zombie included.
  public static func isRunning(_ processIdentifier: Int32) -> Bool {
    guard processIdentifier > 0, kill(processIdentifier, 0) == 0 else {
      return false
    }
    return isZombie(processIdentifier) == false
  }

  /// False once every member of the group has terminated, not-yet-reaped zombies included.
  /// The group id is the session leader's pid, which is the launched child's own pid.
  public static func groupIsRunning(_ processGroup: Int32) -> Bool {
    guard processGroup > 0 else {
      return false
    }
    guard kill(-processGroup, 0) == 0 else {
      // ESRCH is an empty group; anything else (EPERM) means members we cannot signal, which
      // counts as running so a reaper keeps escalating rather than declaring victory.
      return errno != ESRCH
    }
    guard let members = runningMembers(of: processGroup) else {
      // No way to enumerate the group on this platform, so trust the signal probe. Darwin reaps
      // orphans through launchd, which makes a lingering zombie the exception rather than the rule.
      return true
    }
    return members > 0
  }
}

// MARK: - Zombie Detection

private extension ProcessLiveness {
  #if canImport(Glibc)
    /// `/proc/<pid>/stat` field 3 is the state character, and `Z` is the terminated-but-unreaped
    /// one. The comm field (2) is parenthesized and may itself contain spaces, so the scan starts
    /// after the last `)` rather than splitting the whole line.
    static func state(of processIdentifier: Int32) -> Character? {
      guard
        let raw = try? String(contentsOfFile: "/proc/\(processIdentifier)/stat", encoding: .utf8),
        let afterComm = raw.lastIndex(of: ")")
      else {
        return nil
      }
      let fields = raw[raw.index(after: afterComm)...].split(separator: " ")
      return fields.first?.first
    }

    static func isZombie(_ processIdentifier: Int32) -> Bool {
      state(of: processIdentifier) == "Z"
    }

    /// How many members of the group have not terminated. Nil when `/proc` cannot be read.
    static func runningMembers(of processGroup: Int32) -> Int? {
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
        return nil
      }
      var running = 0
      for entry in entries {
        guard let candidate = Int32(entry), groupOf(candidate) == processGroup else {
          continue
        }
        if isZombie(candidate) == false {
          running += 1
        }
      }
      return running
    }

    /// `/proc/<pid>/stat` field 5 is the process group id, counting from the state character.
    static func groupOf(_ processIdentifier: Int32) -> Int32? {
      guard
        let raw = try? String(contentsOfFile: "/proc/\(processIdentifier)/stat", encoding: .utf8),
        let afterComm = raw.lastIndex(of: ")")
      else {
        return nil
      }
      let fields = raw[raw.index(after: afterComm)...].split(separator: " ")
      // state, ppid, pgrp
      guard fields.count >= 3 else {
        return nil
      }
      return Int32(fields[2])
    }
  #else
    static func isZombie(_ processIdentifier: Int32) -> Bool {
      false
    }

    static func runningMembers(of processGroup: Int32) -> Int? {
      nil
    }
  #endif
}
