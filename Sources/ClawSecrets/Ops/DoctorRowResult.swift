/// One doctor report row's verdict: the rendered value and whether the row passes. Every network-free
/// diagnostic in this module — the secrets decrypt row and the `llm.auth` row — folds into the report
/// through this one shape, so the reporter treats them identically.
public struct DoctorRowResult: Sendable, Equatable {
  public let value: String
  public let ok: Bool

  public init(value: String, ok: Bool) {
    self.value = value
    self.ok = ok
  }
}
