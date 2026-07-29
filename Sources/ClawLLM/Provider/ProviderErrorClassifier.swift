import Foundation

/// Recognises a provider refusing a request because the configured model cannot see images.
///
/// The observed refusal carries a null `code`, so the diagnostic text is the only discriminator
/// there is. The match is deliberately narrow — a rejected request only, an invalid-request
/// rejection only, and an image content-part named in it — because telling the owner to change
/// models over an unrelated outage is worse than showing them the generic failure. Anything short of
/// all three falls through to the existing error path.
enum ProviderErrorClassifier {
  /// The content-part type names the two wire shapes use for an inbound image.
  private static let imagePartMarkers = ["image_url", "input_image"]
  private static let invalidRequestMarker = "invalid_request_error"
  private static let refusalStatus = 400

  /// Never throws and never traps: a body it cannot read is simply not a refusal.
  static func isVisionRefusal(status: Int, body: String) -> Bool {
    guard status == refusalStatus else {
      return false
    }

    let lowered = body.lowercased()
    guard lowered.contains(invalidRequestMarker) else {
      return false
    }

    return imagePartMarkers.contains { marker in
      lowered.contains(marker)
    }
  }

  /// The raw-diagnostic overload. A body that is not UTF-8 is not a refusal.
  static func isVisionRefusal(status: Int, body: Data) -> Bool {
    guard let text = String(data: body, encoding: .utf8) else {
      return false
    }
    return isVisionRefusal(status: status, body: text)
  }
}
