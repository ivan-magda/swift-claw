import ClawCore
import Foundation

// MARK: - Models

/// One model the vendor offers, already cleared for display: the slug has passed the same rule an
/// owner's configured model must pass, and the priority is a real number a sort can order.
public struct ChatGPTCatalogModel: Sendable, Equatable {
  public let slug: String
  public let priority: Double
  public let reasoningLevels: [String]
  public let defaultReasoningLevel: String?

  public init(
    slug: String,
    priority: Double,
    reasoningLevels: [String],
    defaultReasoningLevel: String?
  ) {
    self.slug = slug
    self.priority = priority
    self.reasoningLevels = reasoningLevels
    self.defaultReasoningLevel = defaultReasoningLevel
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
enum ChatGPTCatalogFailure: Error, Sendable, Equatable {
  case unavailable(detail: String)

  var safeDetail: String {
    switch self {
    case .unavailable(let detail):
      ChatGPTProviderMetadata.safeDiagnostic(detail, redacting: [])
    }
  }
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
  static let defaultReasoningLevel = "default_reasoning_level"
  static let supportedReasoningLevels = "supported_reasoning_levels"
  static let effort = "effort"
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

  /// How many reasoning levels one model may list. The vendor offers a handful, and the cap keeps a
  /// broken row from deciding how long its printed line grows.
  static let maximumRetainedReasoningLevels = 16

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
    guard case .object(let fields) = payload, case .array(let rows)? = fields[Catalog.models] else {
      throw ChatGPTCatalogFailure.unavailable(detail: "the model list named no models array")
    }

    var seen: Set<String> = []
    var models: [ChatGPTCatalogModel] = []
    for row in rows {
      guard let model = eligibleModel(in: row), seen.insert(model.slug).inserted else {
        continue
      }
      models.append(model)
    }

    models.sort { first, second in
      first.priority == second.priority
        ? first.slug < second.slug : first.priority < second.priority
    }
    return Array(models.prefix(maximumRetainedModels))
  }
}

// MARK: - Rows

private extension ChatGPTModelCatalog {
  static func eligibleModel(in row: JSONValue) -> ChatGPTCatalogModel? {
    guard case .object(let fields) = row,
          case .string(let slug)? = fields[Catalog.slug],
          LLMProviderRegistry.isValidQualifiedModelSuffix(slug),
          isListed(fields[Catalog.visibility]),
          isOfferedInPicker(fields[Catalog.showInPicker] ?? fields[Catalog.showInPickerAlias])
    else {
      return nil
    }
    return ChatGPTCatalogModel(
      slug: slug,
      priority: priority(fields[Catalog.priority]),
      reasoningLevels: reasoningLevels(fields[Catalog.supportedReasoningLevels]),
      defaultReasoningLevel: reasoningLevel(fields[Catalog.defaultReasoningLevel])
    )
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
    case .bool, .integer, .number, .array, .object:
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
    case .string, .integer, .number, .array, .object:
      return false
    }
  }

  /// Only a finite number is an ordering. A missing, non-numeric, or non-finite priority leaves the
  /// row unranked rather than coerced into a place it did not earn.
  static func priority(_ value: JSONValue?) -> Double {
    switch value {
    case .integer(let stated)?:
      return Double(stated)
    case .number(let stated)? where stated.isFinite:
      return stated
    case nil, .null?, .bool?, .string?, .number?, .array?, .object?:
      return ChatGPTCatalogModel.unrankedPriority
    }
  }
}

// MARK: - Reasoning Levels

private extension ChatGPTModelCatalog {
  static let maximumReasoningLevelScalars = 32

  /// The levels a row lists, in its order. Only the observed shape counts: an array of objects that
  /// each name their level under `effort`. An entry of any other shape is skipped rather than
  /// guessed at, and deduplication precedes the cap for the same reason it does for rows.
  static func reasoningLevels(_ value: JSONValue?) -> [String] {
    guard case .array(let entries)? = value else {
      return []
    }

    var levels: [String] = []
    for entry in entries {
      guard levels.count < maximumRetainedReasoningLevels else {
        break
      }

      guard case .object(let fields) = entry,
            let level = reasoningLevel(fields[Catalog.effort]),
            levels.contains(level) == false
      else {
        continue
      }

      levels.append(level)
    }

    return levels
  }

  /// A level is one short ASCII word, the shape the vendor sends. The list is printed to a
  /// terminal, so anything wider, such as an escape sequence or a phrase, is refused.
  static func reasoningLevel(_ value: JSONValue?) -> String? {
    guard case .string(let level)? = value else {
      return nil
    }

    let scalars = level.unicodeScalars
    guard (1...maximumReasoningLevelScalars).contains(scalars.count),
          scalars.allSatisfy(isReasoningLevelScalar)
    else {
      return nil
    }

    return level
  }

  static func isReasoningLevelScalar(_ scalar: Unicode.Scalar) -> Bool {
    let isLetter = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    let isDigit = ("0"..."9").contains(scalar)
    let isSeparator = scalar == "-" || scalar == "_"
    return isLetter || isDigit || isSeparator
  }
}
