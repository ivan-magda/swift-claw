import Foundation

// MARK: - Provider identity

/// The durable identity of a provider route. Its raw value keys stored credentials and the
/// qualified model prefix an owner types, so changing one is a migration, not a rename.
public struct LLMProviderID: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let openAICompatible = LLMProviderID(rawValue: "openai-compatible")
  public static let openAIChatGPT = LLMProviderID(rawValue: "openai-chatgpt")
}

/// What makes a provider-keyed dictionary encode as a JSON object rather than the flat, iteration-
/// ordered `["openai-chatgpt", {…}, "openai-compatible", {…}]` array `Dictionary` emits for every
/// key type that is not `String`, `Int`, or this protocol. The stored credential map is keyed by
/// this type, so the conformance is part of that file's on-disk shape: adding it after the format
/// ships would silently reinterpret a file holding an owner's only refresh token, and dropping it
/// would make the bytes depend on a per-process hash seed.
extension LLMProviderID: CodingKeyRepresentable {}

extension LLMProviderID: CustomStringConvertible {
  /// The bare identity an owner configured, for diagnostics that carry this as a payload: config
  /// errors reach the operator through reflection, which would otherwise render the wrapper.
  public var description: String { rawValue }
}

/// How a route authorizes. Authentication and wire protocol are separate choices: this names the
/// credential seam to compose, never the wire format.
public enum LLMCredentialMode: Sendable, Equatable {
  case noneOrStaticBearer
  case managedOAuth
}

/// Which JSON key carries the output cap on the wire, or `omitted` for a route that honors none —
/// where the configured cap degrades to a local reservation rather than a provider-enforced bound.
public enum LLMWireOutputTokenField: Sendable, Equatable {
  case configured(MaxTokensField)
  case omitted
}

/// What a route's wire contract offers. Composition validates configuration against these before
/// any network I/O; the agent loop never reads them.
public struct LLMProviderCapabilities: Sendable, Equatable {
  public let supportsTools: Bool
  /// Whether SSE is the route's only transport, buffered replies included: a `complete()` here
  /// drains the very event stream a `stream()` does. This is not "offers streaming" — `stream()` is
  /// a protocol requirement every conformer exposes, so its presence distinguishes no route from
  /// another — and the owner-facing streaming toggle never moves it, governing whether partial text
  /// reaches the owner rather than what crosses the wire. False marks a route whose buffered and
  /// streamed calls are genuinely different transports, and which can therefore fall back from one
  /// to the other.
  public let usesStreamingWire: Bool
  public let supportsStructuredOutput: Bool
  public let supportsStopStrings: Bool
  public let outputTokenField: LLMWireOutputTokenField

  public init(
    supportsTools: Bool,
    usesStreamingWire: Bool,
    supportsStructuredOutput: Bool,
    supportsStopStrings: Bool,
    outputTokenField: LLMWireOutputTokenField
  ) {
    self.supportsTools = supportsTools
    self.usesStreamingWire = usesStreamingWire
    self.supportsStructuredOutput = supportsStructuredOutput
    self.supportsStopStrings = supportsStopStrings
    self.outputTokenField = outputTokenField
  }
}

/// Where a route's inference traffic leaves for. It is an identity, never a credential: policy
/// fingerprints fold it so switching sinks invalidates a parked approval even when no base URL is
/// configured at all.
public enum LLMEgressIdentity: Sendable, Equatable, Hashable {
  case configuredEndpoint(String)
  case managed(providerID: LLMProviderID, endpoint: String)
}

/// One registered provider route. `qualifiedPrefix` is nil for the fallback route, which is
/// selected by no prefix at all.
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
  /// The Codex Responses endpoint is a compile-time constant, never configuration. Bearers are
  /// built only after this fixed URL is selected, so a user-supplied base URL structurally cannot
  /// receive a subscription token.
  public static let chatGPTResponsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"

  /// The managed ChatGPT route. The studied backend honors no output-token cap and offers no
  /// relied-upon structured-output or stop-string contract, so those are refused at configuration
  /// rather than silently degraded at runtime.
  public static let openAIChatGPT = LLMProviderDescriptor(
    providerID: .openAIChatGPT,
    qualifiedPrefix: "openai-chatgpt/",
    egress: .managed(providerID: .openAIChatGPT, endpoint: chatGPTResponsesEndpoint),
    credentialMode: .managedOAuth,
    capabilities: LLMProviderCapabilities(
      supportsTools: true,
      usesStreamingWire: true,
      supportsStructuredOutput: false,
      supportsStopStrings: false,
      outputTokenField: .omitted
    )
  )

  /// The configured OpenAI-compatible Chat Completions route — the supported default, and the
  /// fallback every unqualified model resolves to.
  public static func openAICompatible(endpoint: String) -> LLMProviderDescriptor {
    LLMProviderDescriptor(
      providerID: .openAICompatible,
      qualifiedPrefix: nil,
      egress: .configuredEndpoint(endpoint),
      credentialMode: .noneOrStaticBearer,
      capabilities: LLMProviderCapabilities(
        supportsTools: true,
        usesStreamingWire: false,
        supportsStructuredOutput: true,
        supportsStopStrings: true,
        outputTokenField: .configured(AppConfig.EnvDefaults.maxTokensField)
      )
    )
  }
}

// MARK: - Resolved route

/// `CLAW_LLM_MODEL` parsed once. `configuredReference` is the accounting and diagnostic identity;
/// `wireModel` is what goes on the wire. Collapsing the two would let subscription and API-billed
/// calls for the same wire model share one usage identity.
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
  /// Resolves a configured model reference to its route. The base URL is an autoclosure because a
  /// managed route must neither read nor require one: the model is validated first, and a
  /// configured endpoint is only demanded once the fallback route is chosen.
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
      descriptor: .openAICompatible(endpoint: canonicalEndpoint(try configuredBaseURL())),
      configuredReference: modelReference,
      wireModel: modelReference
    )
  }
}

// MARK: - Route Selection

private extension LLMProviderRegistry {
  /// Every descriptor a qualified reference can select. The fallback route carries no prefix and is
  /// matched by nothing, so it is deliberately absent: adding a managed provider registers a
  /// descriptor here rather than adding a branch downstream.
  static let qualifiedDescriptors: [LLMProviderDescriptor] = [.openAIChatGPT]

  static let maximumQualifiedSuffixScalars = 200

  /// Matches raw UTF-8 rather than characters, so recognition is exact bytes: Swift's grapheme and
  /// canonical-equivalence rules must not decide which provider an owner's model reaches. Strips
  /// once — `openai-chatgpt/team/model` sends `team/model`.
  static func strippingPrefix(_ prefix: String, from reference: String) -> String? {
    guard reference.utf8.starts(with: prefix.utf8) else {
      return nil
    }
    // Slicing the reference's own UTF-8 view is lossless, so the failable Data initializer the
    // rule prefers has no failure to report here — only an optional to unwrap.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: reference.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
  }
}

// MARK: - Suffix Validation

private extension LLMProviderRegistry {
  /// Enforces `[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}` by scalar membership: a bounded walk over a
  /// fixed set, with no regex engine reachable from a configured string.
  static func validateQualifiedSuffix(_ suffix: String, reference: String) throws {
    let scalars = suffix.unicodeScalars
    guard let leading = scalars.first else {
      throw ConfigError.emptyQualifiedModelSuffix(reference: reference)
    }
    guard scalars.count <= maximumQualifiedSuffixScalars else {
      throw ConfigError.oversizedQualifiedModelSuffix(reference: reference)
    }
    guard isAlphanumeric(leading), scalars.dropFirst().allSatisfy(isSafeTrailing) else {
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
  /// Folds endpoints that differ only in trailing separators into one egress identity, so an
  /// approval parked under `.../v1` survives a later `.../v1/` that reaches the same sink. The wire
  /// adapter appends its own path, so the stored form never keeps a trailing slash.
  static func canonicalEndpoint(_ configured: String) -> String {
    var canonical = configured.trimmingCharacters(in: .whitespaces)
    while canonical.count > 1, canonical.hasSuffix("/") {
      canonical.removeLast()
    }
    return canonical
  }
}
