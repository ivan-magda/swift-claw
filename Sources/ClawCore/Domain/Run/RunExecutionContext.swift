/// Durable identity and routing for the original run, independent of who approves its action.
public struct RunExecutionContext: Sendable, Equatable {
  public let sessionID: Int64
  public let origin: RunOrigin
  public let requesterUserID: Int64?
  public let mode: ChatMode
  public let deliveryTarget: DeliveryTarget

  public init(
    sessionID: Int64,
    origin: RunOrigin,
    requesterUserID: Int64?,
    mode: ChatMode,
    deliveryTarget: DeliveryTarget
  ) {
    self.sessionID = sessionID
    self.origin = origin
    self.requesterUserID = requesterUserID
    self.mode = mode
    self.deliveryTarget = deliveryTarget
  }
}
