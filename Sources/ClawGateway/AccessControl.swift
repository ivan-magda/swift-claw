import ClawCore

/// The numeric-ID default-deny boundary. Fails CLOSED on any store error.
public struct AccessControl: Sendable {
  private let allowlist: any AllowlistStore

  public init(allowlist: any AllowlistStore) {
    self.allowlist = allowlist
  }

  public func isAllowed(userId: Int64) -> Bool {
    do {
      return try allowlist.allowlistContains(userId: userId)
    } catch {
      return false
    }
  }
}
