import ClawCore
import Foundation

/// Reads a configured model reference as a ChatGPT model, or declines to.
///
/// The registry already owns both halves of that question — which prefix selects this route, and
/// which suffixes a qualified reference may name — so this asks it rather than restating either. A
/// second copy of the prefix rule here would let what status reports drift from what the daemon
/// would actually resolve at boot.
enum ModelSelection {
  /// How many times an owner may miskey an answer before the prompt gives up and takes the default.
  /// A bound rather than a loop: the alternative to giving up is asking forever, and a login that
  /// never returns is worse for an owner than one that picks the model it already told them it
  /// would.
  static let maximumSelectionAttempts = 3

  /// The ChatGPT model a raw reference names, or nil when it names another route's model, no model,
  /// or a suffix the registry would refuse.
  static func configuredChatGPTSuffix(in rawModel: String?) -> String? {
    guard
      let trimmed = rawModel?.trimmingCharacters(in: .whitespaces),
      trimmed.hasPrefix(ChatGPTProviderMetadata.modelPrefix)
    else {
      return nil
    }
    let suffix = String(trimmed.dropFirst(ChatGPTProviderMetadata.modelPrefix.count))
    return LLMProviderRegistry.isValidQualifiedModelSuffix(suffix) ? suffix : nil
  }

  /// The qualified reference status prints back, rebuilt from the suffix rather than echoed: a
  /// reference that reaches a terminal has been through the same rule the daemon resolves with.
  static func qualifiedChatGPTModel(in rawModel: String?) -> String? {
    configuredChatGPTSuffix(in: rawModel).map { suffix in
      "\(ChatGPTProviderMetadata.modelPrefix)\(suffix)"
    }
  }

  /// The assignment printed when there is no catalog to choose from. The variable and the prefix are
  /// the same ones a real choice renders with, so the manual form an owner types by hand cannot
  /// drift from the one the command would have produced.
  static let manualAssignmentForm =
    "\(AppConfig.EnvKey.llmModel)=\(ChatGPTProviderMetadata.modelPrefix)<model>"
}
