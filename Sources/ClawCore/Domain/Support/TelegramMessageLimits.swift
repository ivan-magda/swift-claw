/// Telegram wire limits shared across the delivery and draft-streaming paths. Lives in ClawCore so
/// both `ClawCore` (reply splitting) and `ClawTelegram` (draft streaming) consume one ceiling —
/// ClawCore cannot import ClawTelegram, so the constant must sit here.
public enum TelegramMessageLimits {
  /// Telegram's per-message character ceiling for the rich send path.
  public static let maxRichMessageCharacters = 32_768
}
