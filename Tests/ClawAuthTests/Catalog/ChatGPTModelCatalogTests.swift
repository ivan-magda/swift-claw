import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

/// Scripted catalog payloads, built as `JSONValue` rather than text so a case can state the
/// non-finite priorities no JSON document can encode but a decoder's `Double` can still hold.
private enum CatalogFixture {
  static let slug = "gpt-5.4"
  static let accessToken = "access-token-value"

  static let authorization = LLMRequestAuthorization(
    headers: ["Authorization": "Bearer \(accessToken)"],
    redactionValues: [accessToken],
    generation: LLMCredentialGeneration(value: 1)
  )

  static func row(
    slug: String = CatalogFixture.slug,
    priority: JSONValue? = nil,
    visibility: JSONValue? = nil,
    picker: (key: String, value: JSONValue)? = nil,
    defaultLevel: JSONValue? = nil,
    supportedLevels: JSONValue? = nil
  ) -> JSONValue {
    var fields: [String: JSONValue] = ["slug": .string(slug)]
    fields["priority"] = priority
    fields["visibility"] = visibility
    if let picker {
      fields[picker.key] = picker.value
    }
    fields["default_reasoning_level"] = defaultLevel
    fields["supported_reasoning_levels"] = supportedLevels
    return .object(fields)
  }

  /// Supported levels in the shape the vendor sends them: one object per level, carrying a
  /// description this parser has no use for.
  static func levelEntries(_ efforts: [String]) -> JSONValue {
    .array(
      efforts.map { effort in
        .object(["effort": .string(effort), "description": .string("Reasoning at \(effort)")])
      }
    )
  }

  static func onlyModel(
    _ rows: [JSONValue],
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> ChatGPTCatalogModel {
    let models = try ChatGPTModelCatalog.eligibleModels(in: payload(rows))
    try #require(models.count == 1, sourceLocation: sourceLocation)
    return models[0]
  }

  static func payload(_ rows: [JSONValue]) -> JSONValue {
    .object(["models": .array(rows)])
  }

  static func slugs(_ rows: [JSONValue]) throws -> [String] {
    try ChatGPTModelCatalog.eligibleModels(in: payload(rows)).map(\.slug)
  }

  /// The scripted payload as the text a response carries. Fails the case rather than substituting
  /// an empty body: a silently blank script would test the parser's answer to nothing at all.
  static func body(_ rows: [JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(payload(rows))
    return try #require(String(bytes: encoded, encoding: .utf8))
  }
}

extension ChatGPTCatalogFailure {
  /// The failure's text, for the cases that assert what a sanitized diagnostic may and may not
  /// carry. Composed at runtime, so it cannot be written into an equality expectation.
  var detailText: String {
    switch self {
    case .unavailable(let detail):
      return detail
    }
  }
}

// MARK: - Parsing

@Suite
struct ChatGPTModelCatalogParsingTests {
  @Test
  func aTopLevelModelsArrayYieldsItsSlugs() throws {
    // given
    let rows = [
      CatalogFixture.row(slug: "gpt-5.4", priority: .number(1)),
      CatalogFixture.row(slug: "gpt-5.4-codex", priority: .number(2)),
    ]

    // when
    let models = try ChatGPTModelCatalog.eligibleModels(in: CatalogFixture.payload(rows))

    // then
    #expect(
      models == [
        ChatGPTCatalogModel(slug: "gpt-5.4", priority: 1),
        ChatGPTCatalogModel(slug: "gpt-5.4-codex", priority: 2),
      ]
    )
  }

  @Test
  func anEmptyModelsArrayInventsNothing() throws {
    // given / when
    let models = try ChatGPTModelCatalog.eligibleModels(in: CatalogFixture.payload([]))

    // then
    #expect(models.isEmpty)
  }

  @Test(arguments: [
    JSONValue.object(["data": .array([CatalogFixture.row()])]),
    JSONValue.object(["models": .object(["gpt-5.4": .number(1)])]),
    JSONValue.object(["models": .string("gpt-5.4")]),
    JSONValue.object([:]),
    JSONValue.array([CatalogFixture.row()]),
    JSONValue.string("gpt-5.4"),
    JSONValue.null,
  ])
  func aPayloadWithoutATopLevelModelsArrayIsUnavailable(payload: JSONValue) throws {
    // given / when / then
    #expect(throws: ChatGPTCatalogFailure.self) {
      try ChatGPTModelCatalog.eligibleModels(in: payload)
    }
  }

  @Test(arguments: [
    JSONValue.number(1),
    JSONValue.string("gpt-5.4"),
    JSONValue.null,
    JSONValue.array([]),
  ])
  func aRowThatIsNotAnObjectIsDiscarded(row: JSONValue) throws {
    // given
    let rows = [row, CatalogFixture.row()]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == [CatalogFixture.slug])
  }
}

// MARK: - Visibility

@Suite
struct ChatGPTModelCatalogVisibilityTests {
  /// The allowlist and its opposites in one table. The excluded values are deliberately not the
  /// `hide`/`hidden` a denylist would name: a parser that only refused those would still offer
  /// `internal` and `unlisted`, and this table is what says so.
  @Test(arguments: [
    (JSONValue?.none, true),
    (JSONValue.null, true),
    (JSONValue.string(""), true),
    (JSONValue.string("   "), true),
    (JSONValue.string("list"), true),
    (JSONValue.string("LIST"), true),
    (JSONValue.string("List"), true),
    (JSONValue.string(" list "), true),
    (JSONValue.string("internal"), false),
    (JSONValue.string("unlisted"), false),
    (JSONValue.string("deprecated"), false),
    (JSONValue.string("experimental"), false),
    (JSONValue.string("hidden"), false),
    (JSONValue.string("hide"), false),
    (JSONValue.string("listed"), false),
    (JSONValue.string("li st"), false),
    (JSONValue.number(1), false),
    (JSONValue.bool(true), false),
    (JSONValue.array([.string("list")]), false),
  ])
  func onlyAnAbsentBlankOrListVisibilityIsEligible(
    visibility: JSONValue?,
    isEligible: Bool
  ) throws {
    // given
    let rows = [CatalogFixture.row(visibility: visibility)]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == (isEligible ? [CatalogFixture.slug] : []))
  }

  @Test(arguments: [
    ("show_in_picker", JSONValue.bool(false), false),
    ("showInPicker", JSONValue.bool(false), false),
    ("show_in_picker", JSONValue.bool(true), true),
    ("showInPicker", JSONValue.bool(true), true),
    ("show_in_picker", JSONValue.null, true),
    ("show_in_picker", JSONValue.string("false"), false),
    ("show_in_picker", JSONValue.string("true"), false),
    ("show_in_picker", JSONValue.number(0), false),
    ("showInPicker", JSONValue.string("false"), false),
  ])
  func bothPickerSpellingsGateTheRow(key: String, value: JSONValue, isEligible: Bool) throws {
    // given
    let rows = [CatalogFixture.row(picker: (key: key, value: value))]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == (isEligible ? [CatalogFixture.slug] : []))
  }

  @Test
  func anAbsentPickerFlagLeavesTheRowEligible() throws {
    // given
    let rows = [CatalogFixture.row()]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == [CatalogFixture.slug])
  }

  @Test
  func aHiddenRowIsDiscardedEvenWhenItsVisibilityIsList() throws {
    // given
    let rows = [
      CatalogFixture.row(
        slug: "internal-fallback",
        visibility: .string("list"),
        picker: (key: "show_in_picker", value: .bool(false))
      ),
      CatalogFixture.row(),
    ]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == [CatalogFixture.slug])
  }
}

// MARK: - Slugs

@Suite
struct ChatGPTModelCatalogSlugTests {
  @Test(arguments: [
    "gpt-5.4",
    "gpt-5.4-codex",
    "gpt_5.4",
    "gpt-5.4:latest",
    "team/model",
    "5",
    String(repeating: "a", count: 200),
  ])
  func aSafeSlugIsKept(slug: String) throws {
    // given
    let rows = [CatalogFixture.row(slug: slug)]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == [slug])
  }

  @Test(arguments: [
    "",
    "gpt 5",
    "gpt\t5",
    "gpt\n5",
    "gpt\05",
    "gpt;rm -rf /",
    "$(id)",
    "gpt&5",
    "gpt|5",
    "-gpt-5.4",
    ".gpt-5.4",
    "/model",
    "gpt-5.4\u{00E9}",
    "gpt\u{200B}5",
    "gpt\u{1B}[31m5",
    String(repeating: "a", count: 201),
  ])
  func anUnsafeSlugNeverReachesTheCatalog(slug: String) throws {
    // given
    let rows = [CatalogFixture.row(slug: slug), CatalogFixture.row()]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == [CatalogFixture.slug])
  }

  @Test(arguments: [
    JSONValue?.none,
    JSONValue.null,
    JSONValue.number(5),
    JSONValue.bool(true),
    JSONValue.array([.string("gpt-5.4")]),
  ])
  func aRowWhoseSlugIsNotAStringIsDiscarded(slug: JSONValue?) throws {
    // given
    var fields: [String: JSONValue] = ["priority": .number(1)]
    fields["slug"] = slug
    let rows = [JSONValue.object(fields), CatalogFixture.row()]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == [CatalogFixture.slug])
  }
}

// MARK: - Priority

@Suite
struct ChatGPTModelCatalogPriorityTests {
  @Test(
    arguments: [(JSONValue?, Double)]([
      (nil, ChatGPTCatalogModel.unrankedPriority),
      (.number(3), 3),
      (.number(0), 0),
      (.number(-1), -1),
      (.number(1.5), 1.5),
      (.number(.nan), ChatGPTCatalogModel.unrankedPriority),
      (.number(.infinity), ChatGPTCatalogModel.unrankedPriority),
      (.number(-.infinity), ChatGPTCatalogModel.unrankedPriority),
      (.null, ChatGPTCatalogModel.unrankedPriority),
      (.string("2"), ChatGPTCatalogModel.unrankedPriority),
      (.bool(true), ChatGPTCatalogModel.unrankedPriority),
    ])
  )
  func onlyAFiniteNumberIsAPriority(priority: JSONValue?, expected: Double) throws {
    // given
    let rows = [CatalogFixture.row(priority: priority)]

    // when
    let models = try ChatGPTModelCatalog.eligibleModels(in: CatalogFixture.payload(rows))

    // then
    #expect(models == [ChatGPTCatalogModel(slug: CatalogFixture.slug, priority: expected)])
  }

  @Test
  func rowsSortByPriorityThenSlug() throws {
    // given
    let rows = [
      CatalogFixture.row(slug: "delta", priority: .number(2)),
      CatalogFixture.row(slug: "bravo", priority: .number(2)),
      CatalogFixture.row(slug: "charlie", priority: .number(1)),
      CatalogFixture.row(slug: "alpha", priority: .number(3)),
    ]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == ["charlie", "bravo", "delta", "alpha"])
  }

  @Test
  func anUnrankedRowSortsBehindEveryRankedOne() throws {
    // given
    let rows = [
      CatalogFixture.row(slug: "alpha", priority: .number(.nan)),
      CatalogFixture.row(slug: "bravo"),
      CatalogFixture.row(slug: "zulu", priority: .number(99)),
    ]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == ["zulu", "alpha", "bravo"])
  }
}

// MARK: - Reasoning Levels

@Suite
struct ChatGPTModelCatalogReasoningLevelTests {
  @Test
  func aRowKeepsItsReasoningLevelsInTheVendorsOrderWithItsDefault() throws {
    // given
    let rows = [
      CatalogFixture.row(
        defaultLevel: .string("medium"),
        supportedLevels: CatalogFixture.levelEntries(["low", "medium", "high"])
      ),
    ]

    // when
    let model = try CatalogFixture.onlyModel(rows)

    // then
    #expect(model.reasoningLevels == ["low", "medium", "high"])
    #expect(model.defaultReasoningLevel == "medium")
  }

  /// Levels are optional detail. A row whose levels this parser cannot read still lists, the way
  /// a row with an unreadable priority does.
  @Test(arguments: [
    JSONValue.string("low"),
    JSONValue.array([.string("low")]),
    JSONValue.array([.object(["effort": .number(1)])]),
  ])
  func unreadableReasoningLevelsLeaveTheRowListedWithoutThem(supported: JSONValue) throws {
    // given
    let rows = [CatalogFixture.row(defaultLevel: .number(1), supportedLevels: supported)]

    // when
    let model = try CatalogFixture.onlyModel(rows)

    // then
    #expect(model.slug == CatalogFixture.slug)
    #expect(model.reasoningLevels.isEmpty)
    #expect(model.defaultReasoningLevel == nil)
  }

  @Test(arguments: [
    "xhigh",
    "High",
    "high-2",
    "very_high",
    String(repeating: "a", count: 32),
  ])
  func aSafeReasoningLevelIsKept(level: String) throws {
    // given
    let rows = [
      CatalogFixture.row(
        defaultLevel: .string(level),
        supportedLevels: CatalogFixture.levelEntries([level])
      ),
    ]

    // when
    let model = try CatalogFixture.onlyModel(rows)

    // then
    #expect(model.reasoningLevels == [level])
    #expect(model.defaultReasoningLevel == level)
  }

  /// The printed list reaches a terminal, so a level must not carry an escape sequence or other
  /// text beyond one short word.
  @Test(arguments: [
    "",
    "very high",
    "high\n",
    "\u{1B}[31mhigh",
    "h\u{00EF}gh",
    "high,low",
    String(repeating: "a", count: 33),
  ])
  func anUnsafeReasoningLevelNeverReachesTheCatalog(level: String) throws {
    // given
    let rows = [
      CatalogFixture.row(
        defaultLevel: .string(level),
        supportedLevels: CatalogFixture.levelEntries([level, "low"])
      ),
    ]

    // when
    let model = try CatalogFixture.onlyModel(rows)

    // then
    #expect(model.reasoningLevels == ["low"])
    #expect(model.defaultReasoningLevel == nil)
  }

  /// Deduplication runs before the cap, as it does for rows: a repeated level cannot spend the
  /// allowance and hide the levels behind it.
  @Test
  func repeatedLevelsAreKeptOnceAndTheListIsBounded() throws {
    // given
    let distinct = (0..<20).map { index in
      "level-\(index)"
    }
    let efforts = Array(repeating: "low", count: 20) + distinct
    let rows = [CatalogFixture.row(supportedLevels: CatalogFixture.levelEntries(efforts))]

    // when
    let model = try CatalogFixture.onlyModel(rows)

    // then
    let retained = ChatGPTModelCatalog.maximumRetainedReasoningLevels
    #expect(model.reasoningLevels == ["low"] + distinct.prefix(retained - 1))
  }
}

// MARK: - Dedup and Cap

@Suite
struct ChatGPTModelCatalogBoundsTests {
  @Test
  func aDuplicateSlugIsKeptOnceAtItsFirstStatedPriority() throws {
    // given
    let rows = [
      CatalogFixture.row(slug: "gpt-5.4", priority: .number(1)),
      CatalogFixture.row(slug: "gpt-5.4", priority: .number(9)),
      CatalogFixture.row(slug: "gpt-5.4", priority: .number(0)),
    ]

    // when
    let models = try ChatGPTModelCatalog.eligibleModels(in: CatalogFixture.payload(rows))

    // then
    #expect(models == [ChatGPTCatalogModel(slug: "gpt-5.4", priority: 1)])
  }

  /// The row that only a dedup-before-cap parser keeps. A parser that capped first would spend its
  /// whole allowance on one repeated slug and never see the second model at all.
  @Test
  func deduplicationPrecedesTheRetainedCap() throws {
    // given
    let repeated = Array(
      repeating: CatalogFixture.row(slug: "repeated", priority: .number(1)),
      count: ChatGPTModelCatalog.maximumRetainedModels
    )
    let rows = repeated + [CatalogFixture.row(slug: "zulu", priority: .number(2))]

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs == ["repeated", "zulu"])
  }

  @Test
  func atMostFiveHundredAndTwelveModelsAreRetained() throws {
    // given
    let rows = (0..<600).map { index in
      CatalogFixture.row(
        slug: "model-\(String(format: "%03d", index))",
        priority: .number(Double(index))
      )
    }

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs.count == ChatGPTModelCatalog.maximumRetainedModels)
    #expect(slugs.first == "model-000")
    #expect(slugs.last == "model-511")
  }

  @Test
  func exactlyFiveHundredAndTwelveModelsSurviveWhole() throws {
    // given
    let rows = (0..<ChatGPTModelCatalog.maximumRetainedModels).map { index in
      CatalogFixture.row(
        slug: "model-\(String(format: "%03d", index))",
        priority: .number(Double(index))
      )
    }

    // when
    let slugs = try CatalogFixture.slugs(rows)

    // then
    #expect(slugs.count == ChatGPTModelCatalog.maximumRetainedModels)
  }
}

// MARK: - Fetch

@Suite
struct ChatGPTModelCatalogFetchTests {
  @Test
  func fetchAsksTheFixedModelsURLWithTheSharedAuthorizationHeaders() async throws {
    // given
    let body = try CatalogFixture.body([CatalogFixture.row(priority: .number(1))])
    let executor = OAuthFixture.executor(
      ChatGPTProviderMetadata.modelsURL,
      OAuthFixture.result(200, body)
    )
    let catalog = ChatGPTModelCatalog(http: executor)

    // when
    let models = try await catalog.fetch(authorization: CatalogFixture.authorization)

    // then
    let request = try #require(await executor.requests.last)
    #expect(models.map(\.slug) == [CatalogFixture.slug])
    #expect(request.url == ChatGPTProviderMetadata.modelsURL)
    #expect(request.method == .get)
    #expect(request.body == nil)
    #expect(request.headers == CatalogFixture.authorization.headers)
    #expect(
      request.responseBodyPolicy
        == .buffered(
          successBytes: ChatGPTProviderMetadata.maximumCatalogResponseBytes,
          errorBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
        )
    )
    #expect(request.selectedBodyCap == ChatGPTProviderMetadata.maximumCatalogResponseBytes)
  }

  @Test
  func aNonSuccessStatusIsUnavailableWithASanitizedDetail() async throws {
    // given
    let executor = OAuthFixture.executor(
      ChatGPTProviderMetadata.modelsURL,
      OAuthFixture.result(500, "\u{1B}]0;pwned\u{7}denied for \(CatalogFixture.accessToken)")
    )
    let catalog = ChatGPTModelCatalog(http: executor)

    // when
    let failure = try await #require(throws: ChatGPTCatalogFailure.self) {
      try await catalog.fetch(authorization: CatalogFixture.authorization)
    }

    // then
    let detail = failure.detailText
    #expect(detail.contains("500"))
    #expect(detail.contains(CatalogFixture.accessToken) == false)
    #expect(detail.contains("\u{1B}") == false)
    #expect(detail.contains("pwned") == false)
  }

  @Test
  func aMalformedSuccessBodyIsUnavailable() async throws {
    // given
    let executor = OAuthFixture.executor(
      ChatGPTProviderMetadata.modelsURL,
      OAuthFixture.result(200, "not json at all")
    )
    let catalog = ChatGPTModelCatalog(http: executor)

    // when / then
    await #expect(throws: ChatGPTCatalogFailure.self) {
      try await catalog.fetch(authorization: CatalogFixture.authorization)
    }
  }

  @Test
  func aTransportFailureIsUnavailableWithARedactedDetail() async throws {
    // given
    let executor = FailingHTTP {
      HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "connection reset carrying \(CatalogFixture.accessToken)"
      )
    }
    let catalog = ChatGPTModelCatalog(http: executor)

    // when
    let failure = try await #require(throws: ChatGPTCatalogFailure.self) {
      try await catalog.fetch(authorization: CatalogFixture.authorization)
    }

    // then
    #expect(failure.detailText.contains(CatalogFixture.accessToken) == false)
  }

  @Test
  func cancellationIsRethrownRatherThanReportedAsAnUnavailableCatalog() async throws {
    // given
    let executor = FailingHTTP {
      CancellationError()
    }
    let catalog = ChatGPTModelCatalog(http: executor)

    // when / then
    await #expect(throws: CancellationError.self) {
      try await catalog.fetch(authorization: CatalogFixture.authorization)
    }
  }
}
