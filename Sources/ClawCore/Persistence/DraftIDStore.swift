/// Allocates negative interactive draft identities, disjoint from positive proactive run IDs.
/// Identities are never reused within the state database.
/// A resumed run receives a new identity after restart, so an old Stop cannot target it.
public protocol DraftIDStore: Sendable {
  func nextID() throws(StoreError) -> Int64
}
