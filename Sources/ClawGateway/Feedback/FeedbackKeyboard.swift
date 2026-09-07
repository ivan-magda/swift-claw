import ClawCore

/// The compact action vocabulary carried by Telegram's bounded `callback_data` field.
public enum FeedbackAction: String, Sendable, Equatable, CaseIterable {
  case resultUseful = "ru"
  case resultNotUseful = "rn"
  case resultCorrection = "rc"
  case evaluationConfirm = "ec"
  case evaluationDispute = "ed"
  case candidateApprove = "ca"
  case candidateReject = "cr"
  case candidateEdit = "ce"
  case promotionRollback = "pr"

  public var signal: OwnerSignal {
    switch self {
    case .resultUseful: .resultUseful
    case .resultNotUseful: .resultNotUseful
    case .resultCorrection: .resultCorrection
    case .evaluationConfirm: .evaluationConfirm
    case .evaluationDispute: .evaluationDispute
    case .candidateApprove: .candidateApprove
    case .candidateReject: .candidateReject
    case .candidateEdit: .candidateEdit
    case .promotionRollback: .promotionRollback
    }
  }

  public var subjectKind: FeedbackSubjectKind {
    signal.feedbackSubjectKind
  }

  public var opensChallenge: Bool {
    signal.opensFeedbackChallenge
  }
}

/// A strict feedback envelope: only `fb:<opaque nonce>:<known action>` survives parsing.
public enum FeedbackKeyboard {
  private static let prefix = "fb"
  private static let domainPrefix = "\(prefix):"

  public static func callbackData(nonce: String, action: FeedbackAction) -> String {
    "\(prefix):\(nonce):\(action.rawValue)"
  }

  public static func belongsToDomain(_ callbackData: String?) -> Bool {
    callbackData?.hasPrefix(domainPrefix) == true
  }

  public static func parse(_ callbackData: String) -> (nonce: String, action: FeedbackAction)? {
    let parts = callbackData.split(separator: ":", omittingEmptySubsequences: false).map(
      String.init
    )
    guard parts.count == 3, parts[0] == prefix else {
      return nil
    }
    let nonce = parts[1]
    guard nonce.isEmpty == false, let action = FeedbackAction(rawValue: parts[2]) else {
      return nil
    }
    return (nonce, action)
  }
}
