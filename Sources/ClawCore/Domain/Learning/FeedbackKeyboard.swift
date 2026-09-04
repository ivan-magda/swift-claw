import Foundation

public enum FeedbackKeyboardError: Error, Sendable, Equatable {
  case invalidMarkup
}

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

  public init(signal: OwnerSignal) {
    switch signal {
    case .resultUseful: self = .resultUseful
    case .resultNotUseful: self = .resultNotUseful
    case .resultCorrection: self = .resultCorrection
    case .evaluationConfirm: self = .evaluationConfirm
    case .evaluationDispute: self = .evaluationDispute
    case .candidateApprove: self = .candidateApprove
    case .candidateReject: self = .candidateReject
    case .candidateEdit: self = .candidateEdit
    case .promotionRollback: self = .promotionRollback
    }
  }

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

/// A strict feedback envelope and canonical inline-keyboard representation.
public enum FeedbackKeyboard {
  public static let maximumCallbackDataBytes = 64

  public struct Button: Sendable, Equatable {
    public let text: String
    public let nonce: String
    public let action: FeedbackAction

    public init(text: String, nonce: String, action: FeedbackAction) {
      self.text = text
      self.nonce = nonce
      self.action = action
    }
  }

  private static let prefix = "fb"
  private static let domainPrefix = "\(prefix):"

  public static func callbackData(nonce: String, action: FeedbackAction) -> String {
    "\(prefix):\(nonce):\(action.rawValue)"
  }

  public static func belongsToDomain(_ callbackData: String?) -> Bool {
    callbackData?.hasPrefix(domainPrefix) == true
  }

  public static func parse(_ callbackData: String) -> (nonce: String, action: FeedbackAction)? {
    guard callbackData.utf8.count <= maximumCallbackDataBytes else {
      return nil
    }
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

  public static func markup(rows: [[Button]]) -> String? {
    guard rows.isEmpty == false, rows.allSatisfy({ $0.isEmpty == false }) else {
      return nil
    }
    var wireRows: [[WireButton]] = []
    for row in rows {
      var wireButtons: [WireButton] = []
      for button in row {
        let callback = callbackData(nonce: button.nonce, action: button.action)
        guard
          let parsed = parse(callback),
          parsed.nonce == button.nonce,
          parsed.action == button.action
        else {
          return nil
        }
        wireButtons.append(WireButton(callbackData: callback, text: button.text))
      }
      wireRows.append(wireButtons)
    }
    let wire = WireMarkup(inlineKeyboard: wireRows)
    return CanonicalJSON.encode(wire)
  }

  public static func parseMarkup(
    _ markup: String
  ) throws(FeedbackKeyboardError) -> [[Button]] {
    guard
      let data = markup.data(using: .utf8),
      let wire = try? JSONDecoder().decode(WireMarkup.self, from: data),
      CanonicalJSON.encode(wire) == markup,
      wire.inlineKeyboard.isEmpty == false,
      wire.inlineKeyboard.allSatisfy({ $0.isEmpty == false })
    else {
      throw .invalidMarkup
    }
    var rows: [[Button]] = []
    for row in wire.inlineKeyboard {
      var buttons: [Button] = []
      for button in row {
        guard let callback = parse(button.callbackData) else {
          throw .invalidMarkup
        }
        buttons.append(
          Button(text: button.text, nonce: callback.nonce, action: callback.action)
        )
      }
      rows.append(buttons)
    }
    return rows
  }

  public static func candidateReviewMarkup(
    targets: [NewFeedbackTarget],
    evaluations: [CandidateEvaluationSource]
  ) -> String? {
    guard targets.count == evaluations.count + 1 else {
      return nil
    }
    let rows = targets.enumerated().map { index, target in
      let evaluationRunId = index > 0 ? evaluations[index - 1].runId : nil
      return target.allowedActions.map { signal in
        Button(
          text: reviewLabel(signal, evaluationRunId: evaluationRunId),
          nonce: target.nonce,
          action: FeedbackAction(signal: signal)
        )
      }
    }
    return markup(rows: rows)
  }

  private static func reviewLabel(_ signal: OwnerSignal, evaluationRunId: Int64?) -> String {
    switch signal {
    case .candidateApprove: "Approve"
    case .candidateReject: "Reject"
    case .candidateEdit: "Edit"
    case .evaluationConfirm: "Eval #\(evaluationRunId ?? 0) correct"
    case .evaluationDispute: "Eval #\(evaluationRunId ?? 0) wrong"
    case .resultUseful, .resultNotUseful, .resultCorrection, .promotionRollback:
      signal.rawValue
    }
  }
}

private extension FeedbackKeyboard {
  struct WireMarkup: Codable {
    let inlineKeyboard: [[WireButton]]

    enum CodingKeys: String, CodingKey {
      case inlineKeyboard = "inline_keyboard"
    }
  }

  struct WireButton: Codable {
    let callbackData: String
    let text: String

    enum CodingKeys: String, CodingKey {
      case callbackData = "callback_data"
      case text
    }
  }
}
