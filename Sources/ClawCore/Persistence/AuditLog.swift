public protocol AuditLog: Sendable {
  func appendAudit(_ event: AuditEvent) throws
}
