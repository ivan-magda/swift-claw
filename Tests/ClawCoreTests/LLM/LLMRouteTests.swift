import ClawCore
import Testing

/// Records every evaluation of the base-URL autoclosure, so a route that must not read the
/// configured endpoint can be proven not to have read it rather than merely assumed clean.
/// Constructed with no value it throws, which turns an unwanted evaluation into a test failure.
private final class BaseURLProbe {
  private(set) var accessCount = 0
  private let value: String?

  init(returning value: String? = nil) {
    self.value = value
  }

  func read() throws -> String {
    accessCount += 1
    guard let value else {
      throw ProbeFailure.evaluated
    }
    return value
  }
}

private enum ProbeFailure: Error, Equatable {
  case evaluated
}

@Suite struct LLMRouteTests {
  // MARK: - Provider Identity

  @Test func providerIdentitiesAreStableStrings() {
    // given / when / then
    #expect(LLMProviderID.openAICompatible.rawValue == "openai-compatible")
    #expect(LLMProviderID.openAIChatGPT.rawValue == "openai-chatgpt")
  }

  // MARK: - Managed Route Selection

  @Test(arguments: [
    ("openai-chatgpt/gpt-5.4-codex", "gpt-5.4-codex"),
    ("openai-chatgpt/team/model", "team/model"),
    ("openai-chatgpt/openai-chatgpt/model", "openai-chatgpt/model"),
  ])
  func exactPrefixSelectsTheManagedRouteAndStripsThePrefixOnce(
    reference: String,
    expectedWireModel: String
  ) throws {
    // given
    let probe = BaseURLProbe()

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: reference,
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.descriptor.providerID == .openAIChatGPT)
    #expect(route.configuredReference == reference)
    #expect(route.wireModel == expectedWireModel)
    #expect(probe.accessCount == 0)
  }

  @Test func theManagedRouteNeitherReadsNorEmbedsTheConfiguredBaseURL() throws {
    // given — a base URL that would resolve successfully if the route ever read it
    let probe = BaseURLProbe(returning: "https://poison.example/v1")

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: "openai-chatgpt/gpt-5.4-codex",
      configuredBaseURL: probe.read()
    )

    // then
    #expect(
      route.descriptor.egress
        == .managed(
          providerID: .openAIChatGPT,
          endpoint: "https://chatgpt.com/backend-api/codex/responses"
        )
    )
    #expect(probe.accessCount == 0)
  }

  @Test func theManagedDescriptorEncodesTheCodexResponsesCapabilities() throws {
    // given
    let probe = BaseURLProbe()

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: "openai-chatgpt/gpt-5.4-codex",
      configuredBaseURL: probe.read()
    )

    // then
    let capabilities = route.descriptor.capabilities
    #expect(route.descriptor.qualifiedPrefix == "openai-chatgpt/")
    #expect(route.descriptor.credentialMode == .managedOAuth)
    #expect(capabilities.supportsTools)
    #expect(capabilities.usesStreamingWire)
    #expect(capabilities.supportsStructuredOutput == false)
    #expect(capabilities.supportsStopStrings == false)
    #expect(capabilities.outputTokenField == .omitted)
  }

  // MARK: - Managed Suffix Validation

  @Test func anEmptyQualifiedSuffixIsAConfigurationError() {
    // given
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when / then
    #expect(throws: ConfigError.emptyQualifiedModelSuffix(reference: "openai-chatgpt/")) {
      try LLMProviderRegistry.resolve(
        modelReference: "openai-chatgpt/",
        configuredBaseURL: probe.read()
      )
    }
    #expect(probe.accessCount == 0)
  }

  @Test func aQualifiedSuffixPastTwoHundredScalarsIsRejected() {
    // given
    let reference = "openai-chatgpt/" + String(repeating: "a", count: 201)
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when / then
    #expect(throws: ConfigError.oversizedQualifiedModelSuffix(reference: reference)) {
      try LLMProviderRegistry.resolve(
        modelReference: reference,
        configuredBaseURL: probe.read()
      )
    }
    #expect(probe.accessCount == 0)
  }

  @Test func aQualifiedSuffixOfExactlyTwoHundredScalarsIsAccepted() throws {
    // given
    let suffix = String(repeating: "a", count: 200)
    let probe = BaseURLProbe()

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: "openai-chatgpt/" + suffix,
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.wireModel == suffix)
  }

  @Test(arguments: [
    "openai-chatgpt/gpt 5",
    "openai-chatgpt/gpt\u{0009}5",
    "openai-chatgpt/gpt\n5",
    "openai-chatgpt/gpt\u{0000}5",
    "openai-chatgpt/gpt;rm -rf /",
    "openai-chatgpt/$(id)",
    "openai-chatgpt/gpt&5",
    "openai-chatgpt/gpt|5",
    "openai-chatgpt/-gpt-5.4",
    "openai-chatgpt/.gpt-5.4",
    "openai-chatgpt//model",
    "openai-chatgpt/gpt-5.4\u{00E9}",
    "openai-chatgpt/gpt\u{200B}5",
  ])
  func unsafeQualifiedSuffixBytesAreRejected(reference: String) {
    // given
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when / then
    #expect(throws: ConfigError.unsafeQualifiedModelSuffix(reference: reference)) {
      try LLMProviderRegistry.resolve(
        modelReference: reference,
        configuredBaseURL: probe.read()
      )
    }
    #expect(probe.accessCount == 0)
  }

  @Test(arguments: [
    "openai-chatgpt/gpt-5.4-codex",
    "openai-chatgpt/team/model",
    "openai-chatgpt/gpt-5.4:latest",
    "openai-chatgpt/gpt_5.4",
    "openai-chatgpt/5",
  ])
  func safeQualifiedSuffixScalarsAreAccepted(reference: String) throws {
    // given
    let probe = BaseURLProbe()

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: reference,
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.descriptor.providerID == .openAIChatGPT)
  }

  // MARK: - Current Route Selection

  @Test(arguments: [
    "gpt-5.4",
    "openrouter/openai/gpt-5.4",
    "team/model",
    "OpenAI-ChatGPT/gpt-5.4",
    "OPENAI-CHATGPT/gpt-5.4",
    "openai-chatgptish/model",
    "openai-chatgpt",
    "openai-chatgpt:gpt-5.4",
    "/openai-chatgpt/gpt-5.4",
    " openai-chatgpt/gpt-5.4",
  ])
  func everyOtherReferenceStaysARawModelOnTheCurrentRoute(reference: String) throws {
    // given
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: reference,
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.descriptor.providerID == .openAICompatible)
    #expect(route.configuredReference == reference)
    #expect(route.wireModel == reference)
    #expect(route.descriptor.egress == .configuredEndpoint("https://api.example.com/v1"))
    #expect(probe.accessCount == 1)
  }

  @Test(arguments: [
    "local model 1",
    "-leading-dash",
    "gpt-5.4\u{00E9}",
  ])
  func rawModelsKeepTheirExistingValidationBehavior(reference: String) throws {
    // given — bytes the managed route rejects; the current route has never validated them
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: reference,
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.wireModel == reference)
  }

  @Test func aRawModelLongerThanTheManagedSuffixCapIsPreservedWhole() throws {
    // given
    let reference = String(repeating: "z", count: 201)
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: reference,
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.wireModel == reference)
  }

  @Test func theCurrentDescriptorKeepsTodaysChatCompletionsCapabilities() throws {
    // given
    let probe = BaseURLProbe(returning: "https://api.example.com/v1")

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: "gpt-5.4",
      configuredBaseURL: probe.read()
    )

    // then
    let capabilities = route.descriptor.capabilities
    #expect(route.descriptor.qualifiedPrefix == nil)
    #expect(route.descriptor.credentialMode == .noneOrStaticBearer)
    #expect(capabilities.supportsTools)
    #expect(capabilities.usesStreamingWire)
    #expect(capabilities.supportsStructuredOutput)
    #expect(capabilities.supportsStopStrings)
    #expect(capabilities.outputTokenField == .configured(.maxCompletionTokens))
  }

  // MARK: - Configured Endpoint

  @Test(arguments: [
    ("https://api.example.com/v1", "https://api.example.com/v1"),
    ("https://api.example.com/v1/", "https://api.example.com/v1"),
    ("https://api.example.com/v1///", "https://api.example.com/v1"),
    ("  https://api.example.com/v1/  ", "https://api.example.com/v1"),
  ])
  func theCurrentRouteCanonicalizesTheConfiguredEndpoint(
    configured: String,
    expected: String
  ) throws {
    // given
    let probe = BaseURLProbe(returning: configured)

    // when
    let route = try LLMProviderRegistry.resolve(
      modelReference: "gpt-5.4",
      configuredBaseURL: probe.read()
    )

    // then
    #expect(route.descriptor.egress == .configuredEndpoint(expected))
    #expect(probe.accessCount == 1)
  }

  @Test func theCurrentRouteSurfacesAnUnresolvableBaseURL() {
    // given
    let probe = BaseURLProbe()

    // when / then
    #expect(throws: ProbeFailure.evaluated) {
      try LLMProviderRegistry.resolve(
        modelReference: "gpt-5.4",
        configuredBaseURL: probe.read()
      )
    }
    #expect(probe.accessCount == 1)
  }
}
