import ClawCore
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ManagedCoderProcessGroup: Sendable {
  static let pollInterval: Duration = .milliseconds(20)
  static let terminationGrace: Duration = .seconds(2)
  static let killGrace: Duration = .seconds(2)

  let receipt: CoderProcessReceipt

  func liveMembers() throws -> [CoderProcessIdentity] {
    guard let pid = receipt.pid, let pgid = receipt.pgid, pid == pgid,
      receipt.hostBootID == (try CoderProcessIdentity.bootID()),
      let leader = try CoderProcessIdentity.read(pid),
      leader.pgid == pgid, leader.birth == receipt.birthIdentity
    else {
      throw IdentityError.unreadable
    }
    return try CoderProcessIdentity.members(of: pgid).filter { member in
      !member.isZombie
    }
  }

  func terminate() async -> Bool {
    do {
      try signal(SIGTERM)
      if try await waitUntilEmpty(for: Self.terminationGrace) { return true }
      try signal(SIGKILL)
      return try await waitUntilEmpty(for: Self.killGrace)
    } catch { return false }
  }
}

// MARK: - Owned group cleanup

private extension ManagedCoderProcessGroup {
  func signal(_ signal: Int32) throws {
    let members = try liveMembers()
    guard !members.isEmpty, let pgid = receipt.pgid else {
      return
    }
    // The verified, unreaped session leader pins this group ID through the signal.
    guard kill(-pgid, signal) == 0 || errno == ESRCH else {
      throw IdentityError.unreadable
    }
  }

  func waitUntilEmpty(for duration: Duration) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: duration)
    repeat {
      if try liveMembers().isEmpty { return true }
      try await Task.sleep(for: Self.pollInterval)
    } while ContinuousClock.now < deadline
    return try liveMembers().isEmpty
  }
}
