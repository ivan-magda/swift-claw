import ClawCore
import ClawTools

/// Scripted DNS resolver for fetch tests: IP literals parse directly (and must never hit the table),
/// named hosts resolve from the injected table, and an unknown host throws
/// `AddressResolutionError.unresolvable`.
public struct ScriptedResolver: AddressResolving {
  public let table: [String: [ResolvedAddress]]

  public init(table: [String: [ResolvedAddress]]) {
    self.table = table
  }

  public func resolve(host: String) async throws -> [ResolvedAddress] {
    if let literal = ResolvedAddress.parse(host) {
      return [literal]
    }
    guard let addresses = table[host] else {
      throw AddressResolutionError.unresolvable(host: host)
    }
    return addresses
  }
}
