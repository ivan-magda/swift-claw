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
  public var description: String { rawValue }
}

public enum LLMCredentialMode: Sendable, Equatable {
  case noneOrStaticBearer
  case managedOAuth
}

public enum LLMWireOutputTokenField: Sendable, Equatable {
  case configured(MaxTokensField)
  case omitted
}

public struct LLMProviderCapabilities: Sendable, Equatable {
  public let supportsStructuredOutput: Bool
  public let outputTokenField: LLMWireOutputTokenField

  public init(
    supportsStructuredOutput: Bool,
    outputTokenField: LLMWireOutputTokenField
  ) {
    self.supportsStructuredOutput = supportsStructuredOutput
    self.outputTokenField = outputTokenField
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

// MARK: - Registered descriptors

extension LLMProviderDescriptor {
  public static let chatGPTResponsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"

  public static let openAIChatGPT = LLMProviderDescriptor(
    providerID: .openAIChatGPT,
    qualifiedPrefix: "openai-chatgpt/",
    egress: .managed(
      providerID: .openAIChatGPT,
      endpoint: chatGPTResponsesEndpoint
    ),
    credentialMode: .managedOAuth,
    capabilities: LLMProviderCapabilities(
      supportsStructuredOutput: false,
      outputTokenField: .omitted
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
        outputTokenField: .configured(AppConfig.EnvDefaults.maxTokensField)
      )
    )
  }
}

// MARK: - Resolved route

/// `CLAW_LLM_MODEL` parsed once. `configuredReference` is the accounting and diagnostic identity;
public struct ResolvedLLMRoute: Sendable, Equatable {
  public let descriptor: LLMProviderDescriptor
  public let configuredReference: String
  public let wireModel: String

  public init(
    descriptor: LLMProviderDescriptor,
    configuredReference: String,
    wireModel: String
  ) {
    self.descriptor = descriptor
    self.configuredReference = configuredReference
    self.wireModel = wireModel
  }
}

// MARK: - Registry

public enum LLMProviderRegistry {
  public static func resolve(
    modelReference: String,
    configuredBaseURL: @autoclosure () throws -> String
  ) throws -> ResolvedLLMRoute {
    for descriptor in qualifiedDescriptors {
      guard
        let prefix = descriptor.qualifiedPrefix,
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
      descriptor: .openAICompatible(
        endpoint: canonicalEndpoint(try configuredBaseURL())
      ),
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

    guard
      isAlphanumeric(leading),
      scalars.dropFirst().allSatisfy(isSafeTrailing)
    else {
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
