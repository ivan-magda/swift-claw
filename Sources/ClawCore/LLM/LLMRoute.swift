import Foundation

// MARK: - Provider identity

public struct LLMProviderID: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let openAICompatible = LLMProviderID(rawValue: "openai-compatible")
  public static let openAIChatGPT = LLMProviderID(rawValue: "openai-chatgpt")
}

/// What makes a provider-keyed dictionary encode as a JSON object rather than the flat, iteration-
/// ordered `["openai-chatgpt", {…}, "openai-compatible", {…}]`.
extension LLMProviderID: CodingKeyRepresentable {}

extension LLMProviderID: CustomStringConvertible {
  public var description: String {
    rawValue
  }
}

public enum LLMCredentialMode: Sendable, Equatable {
  case noneOrStaticBearer
  case managedOAuth
}

public enum LLMWireOutputTokenField: Sendable, Equatable {
  case configured(MaxTokensField)
  case omitted
}

/// What a route's requests say about reasoning effort. A route with no such field is `unsupported`
/// and never reads the setting; one that has it sends nothing until the owner configures a level.
public enum LLMWireReasoningEffort: Sendable, Equatable {
  case unsupported
  case providerDefault
  case configured(LLMReasoningEffort)

  /// The level to put on the wire, or nil when the request should carry none.
  public var configuredLevel: LLMReasoningEffort? {
    guard case .configured(let level) = self else {
      return nil
    }
    return level
  }
}

/// Mutable fields so a parser that settles one route-owned wire option copies every other field
/// with the value, rather than rebuilding them by hand and dropping one added later.
public struct LLMProviderCapabilities: Sendable, Equatable {
  public var supportsStructuredOutput: Bool
  public var outputTokenField: LLMWireOutputTokenField
  public var reasoningEffort: LLMWireReasoningEffort

  public init(
    supportsStructuredOutput: Bool,
    outputTokenField: LLMWireOutputTokenField,
    reasoningEffort: LLMWireReasoningEffort
  ) {
    self.supportsStructuredOutput = supportsStructuredOutput
    self.outputTokenField = outputTokenField
    self.reasoningEffort = reasoningEffort
  }
}

public enum LLMEgressIdentity: Sendable, Equatable, Hashable {
  case configuredEndpoint(String)
  case managed(providerID: LLMProviderID, endpoint: String)
}

public struct LLMProviderDescriptor: Sendable, Equatable {
  public let providerID: LLMProviderID
  public let qualifiedPrefix: String?
  public let egress: LLMEgressIdentity
  public let credentialMode: LLMCredentialMode
  public let capabilities: LLMProviderCapabilities

  public init(
    providerID: LLMProviderID,
    qualifiedPrefix: String?,
    egress: LLMEgressIdentity,
    credentialMode: LLMCredentialMode,
    capabilities: LLMProviderCapabilities
  ) {
    self.providerID = providerID
    self.qualifiedPrefix = qualifiedPrefix
    self.egress = egress
    self.credentialMode = credentialMode
    self.capabilities = capabilities
  }
}

// MARK: - Billing

extension LLMProviderDescriptor {
  /// How calls on this provider are billed: a managed subscription is included in the owner's plan,
  /// and a static-key or keyless endpoint is metered per token. Composition stamps it on the route
  /// binding; config parsing and doctor read the same answer.
  public var costPolicy: LLMCostPolicy {
    switch credentialMode {
    case .noneOrStaticBearer:
      .metered
    case .managedOAuth:
      .includedPlan
    }
  }
}

// MARK: - Registered descriptors

extension LLMProviderDescriptor {
  public static let chatGPTResponsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"

  public static let openAIChatGPT = LLMProviderDescriptor(
    providerID: .openAIChatGPT,
    qualifiedPrefix: "openai-chatgpt/",
    egress: .managed(providerID: .openAIChatGPT, endpoint: chatGPTResponsesEndpoint),
    credentialMode: .managedOAuth,
    capabilities: LLMProviderCapabilities(
      supportsStructuredOutput: false,
      outputTokenField: .omitted,
      reasoningEffort: .providerDefault
    )
  )

  public static func openAICompatible(endpoint: String) -> LLMProviderDescriptor {
    LLMProviderDescriptor(
      providerID: .openAICompatible,
      qualifiedPrefix: nil,
      egress: .configuredEndpoint(endpoint),
      credentialMode: .noneOrStaticBearer,
      capabilities: LLMProviderCapabilities(
        supportsStructuredOutput: true,
        outputTokenField: .configured(AppConfig.EnvDefaults.maxTokensField),
        reasoningEffort: .unsupported
      )
    )
  }
}

// MARK: - Resolved route

/// A model route resolved once from `CLAW_LLM_MODEL`.
///
/// `configuredReference` retains the configured accounting and diagnostic identity; `wireModel`
/// is the model name sent to the provider.
public struct ResolvedLLMRoute: Sendable, Equatable {
  public let descriptor: LLMProviderDescriptor
  public let configuredReference: String
  public let wireModel: String

  public init(descriptor: LLMProviderDescriptor, configuredReference: String, wireModel: String) {
    self.descriptor = descriptor
    self.configuredReference = configuredReference
    self.wireModel = wireModel
  }
}

extension ResolvedLLMRoute {
  /// The same route with its descriptor's capabilities replaced: the one step configuration parsing
  /// takes to settle a route-owned wire option after the registry has resolved the route.
  func replacingCapabilities(_ capabilities: LLMProviderCapabilities) -> ResolvedLLMRoute {
    ResolvedLLMRoute(
      descriptor: LLMProviderDescriptor(
        providerID: descriptor.providerID,
        qualifiedPrefix: descriptor.qualifiedPrefix,
        egress: descriptor.egress,
        credentialMode: descriptor.credentialMode,
        capabilities: capabilities
      ),
      configuredReference: configuredReference,
      wireModel: wireModel
    )
  }
}

// MARK: - Registry

public enum LLMProviderRegistry {
  public static func resolve(
    modelReference: String,
    configuredBaseURL: @autoclosure () throws -> String
  ) throws -> ResolvedLLMRoute {
    for descriptor in qualifiedDescriptors {
      guard let prefix = descriptor.qualifiedPrefix,
            let suffix = strippingPrefix(prefix, from: modelReference)
      else {
        continue
      }

      try validateQualifiedSuffix(suffix, reference: modelReference)

      return ResolvedLLMRoute(
        descriptor: descriptor,
        configuredReference: modelReference,
        wireModel: suffix
      )
    }

    return ResolvedLLMRoute(
      descriptor: .openAICompatible(endpoint: canonicalEndpoint(try configuredBaseURL())),
      configuredReference: modelReference,
      wireModel: modelReference
    )
  }

  public static func isValidQualifiedModelSuffix(_ suffix: String) -> Bool {
    qualifiedSuffixRejection(suffix) == nil
  }
}

// MARK: - Route Selection

private extension LLMProviderRegistry {
  static let qualifiedDescriptors: [LLMProviderDescriptor] = [.openAIChatGPT]

  static let maximumQualifiedSuffixScalars = 200

  static func strippingPrefix(_ prefix: String, from reference: String) -> String? {
    guard reference.hasPrefix(prefix) else {
      return nil
    }
    return String(reference.dropFirst(prefix.count))
  }
}

// MARK: - Suffix Validation

private extension LLMProviderRegistry {
  enum QualifiedSuffixRejection {
    case empty
    case oversized
    case unsafe
  }

  static func qualifiedSuffixRejection(_ suffix: String) -> QualifiedSuffixRejection? {
    let scalars = suffix.unicodeScalars

    guard let leading = scalars.first else {
      return .empty
    }

    guard scalars.count <= maximumQualifiedSuffixScalars else {
      return .oversized
    }

    guard isAlphanumeric(leading), scalars.dropFirst().allSatisfy(isSafeTrailing) else {
      return .unsafe
    }

    return nil
  }

  static func validateQualifiedSuffix(_ suffix: String, reference: String) throws {
    switch qualifiedSuffixRejection(suffix) {
    case nil:
      return
    case .empty:
      throw ConfigError.emptyQualifiedModelSuffix(reference: reference)
    case .oversized:
      throw ConfigError.oversizedQualifiedModelSuffix(reference: reference)
    case .unsafe:
      throw ConfigError.unsafeQualifiedModelSuffix(reference: reference)
    }
  }

  static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
  }

  static func isSafeTrailing(_ scalar: Unicode.Scalar) -> Bool {
    isAlphanumeric(scalar) || safeTrailingPunctuation.contains(scalar)
  }

  static let safeTrailingPunctuation: Set<Unicode.Scalar> = Set(".:_-/".unicodeScalars)
}

// MARK: - Configured Endpoint

private extension LLMProviderRegistry {
  static func canonicalEndpoint(_ configured: String) -> String {
    var canonical = configured.trimmingCharacters(in: .whitespaces)

    while canonical.count > 1, canonical.hasSuffix("/") {
      canonical.removeLast()
    }

    return canonical
  }
}
