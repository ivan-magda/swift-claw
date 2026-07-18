import ClawCore
import Foundation

// MARK: - Models

/// One model the vendor offers, already cleared for display: the slug has passed the same rule an
/// owner's configured model must pass, and the priority is a real number a sort can order.
public struct ChatGPTCatalogModel: Sendable, Equatable {
  public let slug: String
  public let priority: Double

  public init(slug: String, priority: Double) {
    self.slug = slug
    self.priority = priority
  }

  /// What a row weighs when the vendor stated no ordering this parser can act on. It sorts behind
  /// every ranked row rather than ahead of them, so a broken or absent priority costs a model its
  /// place in the list and never the top of it. Finite on purpose: a NaN admitted into a sort
  /// comparator would make the ordering itself undefined.
  public static let unrankedPriority = Double.greatestFiniteMagnitude
}

/// Why no catalog came back. A caller answers every case the same way — say login succeeded and
/// print the assignment for the owner to set by hand — so the type names one outcome rather than a
/// taxonomy nobody branches on. What it must never be is a login failure: the credential is already
/// stored and valid by the time anything asks what models exist.
public enum ChatGPTCatalogFailure: Error, Sendable, Equatable {
  case unavailable(detail: String)
}

public protocol ChatGPTModelCatalogFetching: Sendable {
  func fetch(authorization: LLMRequestAuthorization) async throws -> [ChatGPTCatalogModel]
}

// MARK: - Catalog

/// Reads the live list of models a subscription may name. It fetches, bounds, and orders; it does
/// not cache — a catalog is a fact about right now, and a stale copy on disk would outlive the
/// question it answered.
public struct ChatGPTModelCatalog: Sendable, ChatGPTModelCatalogFetching {
  private let http: any HTTPExecuting

  public init(http: any HTTPExecuting) {
    self.http = http
  }

  /// Asks the vendor which models this credential may use.
  ///
  /// - Throws: `ChatGPTCatalogFailure` for anything the vendor or the transport did, or
  ///   `CancellationError` when the caller walked away.
  public func fetch(authorization: LLMRequestAuthorization) async throws -> [ChatGPTCatalogModel] {
    let response = try await send(authorization: authorization)

    guard HTTPResponseBodyPolicy.isSuccess(response.statusCode) else {
      // Lossy on purpose: a diagnostic body that is not valid UTF-8 is still a diagnostic.
      // swiftlint:disable:next optional_data_string_conversion
      let body = String(decoding: response.body, as: UTF8.self)
      throw ChatGPTCatalogFailure.unavailable(
        detail: ChatGPTProviderMetadata.safeDiagnostic(
          "status \(response.statusCode): \(body)",
          redacting: authorization.redactionValues
        )
      )
    }

    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
      throw ChatGPTCatalogFailure.unavailable(detail: "the model list was not JSON")
    }
    return try Self.eligibleModels(in: decoded)
  }
}

// MARK: - Wire Vocabulary

private enum Catalog {
  static let models = "models"
  static let slug = "slug"
  static let priority = "priority"
  static let visibility = "visibility"
  static let showInPicker = "show_in_picker"
  /// The spelling the vendor is also observed to use for the same flag.
  static let showInPickerAlias = "showInPicker"
  static let listedVisibility = "list"
}

// MARK: - Requests

private extension ChatGPTModelCatalog {
  /// Caps both bodies at read time — a success body is the payload, a non-success one is a
  /// diagnostic worth only its first few kilobytes, and neither is worth materializing whole before
  /// anything trims it.
  func send(authorization: LLMRequestAuthorization) async throws -> HTTPResult {
    let request = HTTPRequest(
      method: .get,
      url: ChatGPTProviderMetadata.modelsURL,
      headers: authorization.headers,
      body: nil,
      timeout: .seconds(
        ChatGPTProviderMetadata.transportSeconds(ChatGPTProviderMetadata.requestTimeout)
      ),
      responseBodyPolicy: .buffered(
        successBytes: ChatGPTProviderMetadata.maximumCatalogResponseBytes,
        errorBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
      )
    )

    return try await ChatGPTProviderMetadata.execute(
      request,
      on: http,
      redacting: authorization.redactionValues
    ) { detail in
      ChatGPTCatalogFailure.unavailable(detail: detail)
    }
  }
}

// MARK: - Parsing

extension ChatGPTModelCatalog {
  /// How many models are worth offering. A list this long is already past what any owner reads, and
  /// the cap is what stops a broken or hostile response from deciding how much the daemon holds.
  static let maximumRetainedModels = 512

  /// The models a response actually offers, in the order they should be shown.
  ///
  /// Only a top-level `models` array is a catalog. Anything else is a response this parser does not
  /// understand, and guessing at a shape — reading `data`, or accepting a bare array — would be
  /// inventing a contract the vendor never published.
  ///
  /// Every row that survives has cleared display: an unusable slug, an ineligible row, and a
  /// duplicate are all gone before a caller can print one. Deduplication runs before the cap, so a
  /// response repeating one slug cannot spend the whole allowance and hide the models behind it.
  static func eligibleModels(in payload: JSONValue) throws -> [ChatGPTCatalogModel] {
    guard
      case .object(let fields) = payload,
      case .array(let rows)? = fields[Catalog.models]
    else {
      throw ChatGPTCatalogFailure.unavailable(detail: "the model list named no models array")
    }

    var seen: Set<String> = []
    var models: [ChatGPTCatalogModel] = []
    for row in rows {
      guard
        let model = eligibleModel(in: row),
        seen.insert(model.slug).inserted
      else {
        continue
      }
      models.append(model)
    }

    models.sort { first, second in
      first.priority == second.priority
        ? first.slug < second.slug
        : first.priority < second.priority
    }
    return Array(models.prefix(maximumRetainedModels))
  }
}

// MARK: - Rows

private extension ChatGPTModelCatalog {
  static func eligibleModel(in row: JSONValue) -> ChatGPTCatalogModel? {
    guard
      case .object(let fields) = row,
      case .string(let slug)? = fields[Catalog.slug],
      LLMProviderRegistry.isValidQualifiedModelSuffix(slug),
      isListed(fields[Catalog.visibility]),
      isOfferedInPicker(fields[Catalog.showInPicker] ?? fields[Catalog.showInPickerAlias])
    else {
      return nil
    }
    return ChatGPTCatalogModel(slug: slug, priority: priority(fields[Catalog.priority]))
  }

  /// An allowlist, and deliberately not the denylist of hidden spellings a reader might expect. A
  /// denylist offers every visibility nobody thought to name — the vendor's internal fallback rows
  /// among them — so an unrecognized value is refused rather than guessed at. A row the vendor
  /// really did mean to list costs nothing worse than being absent until this list learns its word.
  static func isListed(_ value: JSONValue?) -> Bool {
    switch value {
    case nil, .null?:
      return true
    case .string(let raw)?:
      let stated = raw.trimmingCharacters(in: .whitespaces)
      return stated.isEmpty || stated.lowercased() == Catalog.listedVisibility
    case .bool, .number, .array, .object:
      return false
    }
  }

  /// The picker flag read the same way round: only an absent flag or an explicit `true` offers the
  /// row. A value of some other shape is a flag this parser cannot read, and a row whose own
  /// response may be trying to say "do not show this" is not one to show on a coin toss.
  static func isOfferedInPicker(_ value: JSONValue?) -> Bool {
    switch value {
    case nil, .null?:
      return true
    case .bool(let isOffered)?:
      return isOffered
    case .string, .number, .array, .object:
      return false
    }
  }

  /// Only a finite number is an ordering. A missing, non-numeric, or non-finite priority leaves the
  /// row unranked rather than coerced into a place it did not earn.
  static func priority(_ value: JSONValue?) -> Double {
    guard case .number(let stated)? = value, stated.isFinite else {
      return ChatGPTCatalogModel.unrankedPriority
    }
    return stated
  }
}

// MARK: - Selection

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
