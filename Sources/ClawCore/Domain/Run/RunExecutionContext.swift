/// Durable identity and routing for the original run, independent of who approves its action.
public struct RunExecutionContext: Sendable, Equatable {
  public let sessionId: Int64
  public let origin: RunOrigin
  public let requesterUserId: Int64?
  public let mode: ChatMode
  public let deliveryTarget: DeliveryTarget

  public init(
    sessionId: Int64,
    origin: RunOrigin,
    requesterUserId: Int64?,
    mode: ChatMode,
    deliveryTarget: DeliveryTarget
  ) {
    self.sessionId = sessionId
    self.origin = origin
    self.requesterUserId = requesterUserId
    self.mode = mode
    self.deliveryTarget = deliveryTarget
  }
}
