import ClawCore

public struct CoderProcessInspector: CoderProcessInspecting {
  public init() {}

  public func inspect(_ receipt: CoderProcessReceipt) async -> CoderRecoveryObservation {
    do {
      let boot = try CoderProcessIdentity.bootID()
      guard !receipt.hostBootID.isEmpty else {
        return .unresolved
      }
      if boot != receipt.hostBootID {
        return .stopped
      }
      guard let pid = receipt.pid,
            let pgid = receipt.pgid,
            let birth = receipt.birthIdentity,
            pid > 0,
            pid == pgid
      else {
        return .unresolved
      }
      let leader = try CoderProcessIdentity.read(pid)
      guard let leader else {
        // A missing leader does not establish that its descendants have stopped.
        let members = try CoderProcessIdentity.members(of: pgid)
        return members.isEmpty ? .stopped : .unresolved
      }
      guard leader.pgid == pgid, leader.birth == birth else {
        return .unresolved
      }
      let members = try CoderProcessIdentity.members(of: pgid)
      let hasLiveMembers = members.contains { member in
        !member.isZombie
      }
      return hasLiveMembers ? .liveOwned : .stopped
    } catch {
      return .unresolved
    }
  }
}
