import ClawCore
import Foundation

/// What a model choice is and where it came from. The origin is what lets the command explain a
/// default it picked without asking.
public enum ChatGPTModelChoiceOrigin: Sendable, Equatable {
  case configuredDefault
  case firstReturnedDefault
  case owner
}

public struct ChatGPTModelChoice: Sendable, Equatable {
  public let slug: String
  public let origin: ChatGPTModelChoiceOrigin

  public init(slug: String, origin: ChatGPTModelChoiceOrigin) {
    self.slug = slug
    self.origin = origin
  }

  /// The exact line an owner may paste. The variable is the one configuration reads and the prefix
  /// is the route's own, so a chosen model resolves back to the provider it came from.
  public var assignment: String {
    "\(AppConfig.EnvKey.llmModel)=\(ChatGPTProviderMetadata.modelPrefix)\(slug)"
  }
}

public enum ChatGPTModelPickerOutcome: Sendable, Equatable {
  case chose(ChatGPTModelChoice)
  /// The owner named a row the numbered list does not have. The caller asks again; nothing here
  /// decides how many times it may.
  case indexOutOfRange
  case noEligibleModels
}

/// Picks a model from a catalog. A pure function of what it is handed: it reads no terminal, no
/// configuration, and no clock, so the same arguments always name the same model — which is what
/// makes the default a non-interactive run takes provably the one a terminal would have offered.
public enum ChatGPTModelPicker {
  /// - Parameters:
  ///   - configuredSuffix: the ChatGPT model already configured, if any. Honored only while the
  ///     catalog still offers it: a default naming a model the vendor has withdrawn would be a
  ///     suggestion that cannot work.
  ///   - chosenIndex: the row an owner named, numbered from one as the printed list is. Ignored
  ///     without a terminal, where no prompt ran and so no answer can have come back.
  public static func select(
    catalog: [ChatGPTCatalogModel],
    configuredSuffix: String?,
    isInteractive: Bool,
    chosenIndex: Int?
  ) -> ChatGPTModelPickerOutcome {
    guard let fallback = catalog.first else {
      return .noEligibleModels
    }

    guard isInteractive, let index = chosenIndex else {
      return .chose(
        defaultChoice(catalog: catalog, configuredSuffix: configuredSuffix, first: fallback)
      )
    }

    // Bounds-checked before the shift to a zero-based offset, not after: `Int.min - 1` traps, and
    // an owner's typed number is the least trustworthy integer in the flow.
    guard index >= 1, index <= catalog.count else {
      return .indexOutOfRange
    }
    return .chose(ChatGPTModelChoice(slug: catalog[index - 1].slug, origin: .owner))
  }
}

// MARK: - Defaults

private extension ChatGPTModelPicker {
  static func defaultChoice(
    catalog: [ChatGPTCatalogModel],
    configuredSuffix: String?,
    first: ChatGPTCatalogModel
  ) -> ChatGPTModelChoice {
    guard
      let configured = configuredSuffix,
      LLMProviderRegistry.isValidQualifiedModelSuffix(configured),
      catalog.contains(where: { $0.slug == configured })
    else {
      return ChatGPTModelChoice(slug: first.slug, origin: .firstReturnedDefault)
    }
    return ChatGPTModelChoice(slug: configured, origin: .configuredDefault)
  }
}
