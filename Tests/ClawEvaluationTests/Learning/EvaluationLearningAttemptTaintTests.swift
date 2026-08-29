import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningAttemptTaintTests {
  @Test func firstProviderRequestContainsOnlyTheCompleteFencedLessonSet() async throws {
    // given
    let fixture = try makeLearningAttemptFixture(lessons: [
      "Preserve punctuation exactly: [a] — café.",
      "Compare the requested regions in their supplied order.",
    ])
    defer { fixture.remove() }
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    _ = try await runLearningAttempt(fixture, provider: provider)
    let firstRequest = try #require(await provider.requests.first)
    let lessonFences = try labeledFences(
      in: firstRequest,
      label: "scheduled_learning_lessons"
    )
    let lesson = try #require(lessonFences.first)

    // then
    #expect(lessonFences.count == 1)
    #expect(lesson == fixture.lessonSetText)
    #expect(SHA256Digest.hex(Data(lesson.utf8)) == fixture.configuration.lessonSetDigest)
    #expect(
      firstRequest.messages.contains { message in
        message.content.text.contains(fixture.beforeHTML)
      } == false
    )
    #expect(
      firstRequest.messages.contains { message in
        message.content.text.contains(fixture.afterHTML)
      } == false
    )
  }

  @Test func secondRequestKeepsLessonAndFileReadFencesDistinct() async throws {
    // given
    let fixture = try makeLearningAttemptFixture(lessons: ["Keep lesson and task data separate."])
    defer { fixture.remove() }
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    _ = try await runLearningAttempt(fixture, provider: provider)
    let requests = await provider.requests
    let secondRequest = try #require(requests.last)
    let lessonFences = try labeledFences(
      in: secondRequest,
      label: "scheduled_learning_lessons"
    )
    let fileReadFences = try labeledFences(in: secondRequest, label: "file_read")

    // then
    #expect(requests.count == 2)
    #expect(lessonFences.count == 1)
    #expect(fileReadFences.count == 1)
    #expect(lessonFences.first == fixture.lessonSetText)
    #expect(
      lessonFences.first.map { lesson in
        SHA256Digest.hex(Data(lesson.utf8))
      } == fixture.configuration.lessonSetDigest
    )
    #expect(
      fileReadFences.first.map { carrier in
        SHA256Digest.hex(Data(carrier.utf8))
      } == fixture.configuration.inputSHA256
    )
  }

  @Test func nonemptyLessonsArmContextAndFirstToolPolicyDecision() async throws {
    // given
    let fixture = try makeLearningAttemptFixture(lessons: ["Treat volatile counters as noise."])
    defer { fixture.remove() }
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    let result = try await runLearningAttempt(fixture, provider: provider)
    let resultObject = try canonicalObject(result)
    let tools = try #require(resultObject["tools"] as? [[String: Any]])

    // then
    #expect(resultObject["learning_initial_tainted"] as? Bool == true)
    #expect(tools.first?["session_tainted"] as? Bool == true)
  }

  @Test func nonemptyLessonsExcludeSensitiveMemoryFromFirstProviderRequest() async throws {
    // given
    let fixture = try makeLearningAttemptFixture(lessons: ["Ignore cosmetic timestamp drift."])
    defer { fixture.remove() }
    let safeMarker = "safe-memory-marker-7f3c"
    let sensitiveMarker = "sensitive-memory-marker-91ad"
    let memoryStore = EvaluationMemoryStoreFixture(items: [
      memoryItem(id: 1, text: safeMarker, sensitivity: .normal),
      memoryItem(id: 2, text: sensitiveMarker, sensitivity: .high),
    ])
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    _ = try await runLearningAttempt(
      fixture,
      provider: provider,
      memoryStore: memoryStore
    )
    let firstRequest = try #require(await provider.requests.first)
    let rendered = firstRequest.messages.map(\.content.text).joined(separator: "\n")

    // then
    #expect(rendered.contains(safeMarker))
    #expect(rendered.contains(sensitiveMarker) == false)
  }

  @Test func cleanLessonsStartUntainted() async throws {
    // given
    let fixture = try makeLearningAttemptFixture(lessons: [])
    defer { fixture.remove() }
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    let result = try await runLearningAttempt(fixture, provider: provider)
    let resultObject = try canonicalObject(result)
    let tools = try #require(resultObject["tools"] as? [[String: Any]])

    // then
    #expect(resultObject["learning_initial_tainted"] as? Bool == false)
    #expect(tools.first?["session_tainted"] as? Bool == false)
  }

  @Test func legacyConfigurationAndResultBytesRemainUnchanged() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let configurationBytes = try EvaluationCanonicalJSON.data(encoding: configured.configuration)
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let result = try await runAttempt(
      configuration: configured.configuration,
      provider: provider,
      memoryStore: EvaluationMemoryStoreFixture(items: [])
    )
    let resultBytes = try EvaluationCanonicalJSON.data(encoding: result)

    // when
    let decodedConfiguration = try JSONDecoder().decode(
      EvaluationAttemptConfiguration.self,
      from: configurationBytes
    )
    let decodedResult = try JSONDecoder().decode(EvaluationAttemptResult.self, from: resultBytes)
    let configurationObject = try canonicalObject(decodedConfiguration)
    let resultObject = try canonicalObject(decodedResult)
    let tools = try #require(resultObject["tools"] as? [[String: Any]])

    // then
    #expect(try EvaluationCanonicalJSON.data(encoding: decodedConfiguration) == configurationBytes)
    #expect(try EvaluationCanonicalJSON.data(encoding: decodedResult) == resultBytes)
    #expect(configurationObject["execution_profile"] == nil)
    #expect(resultObject["learning_carrier_sha256"] == nil)
    #expect(resultObject["learning_lesson_set_sha256"] == nil)
    #expect(resultObject["learning_initial_tainted"] == nil)
    #expect(resultObject["learning_carrier_verified"] == nil)
    #expect(tools.first?["session_tainted"] == nil)
  }
}

struct LearningAttemptFixture {
  let root: URL
  let configuration: EvaluationAttemptConfiguration
  let lessonSetText: String
  let beforeHTML: String
  let afterHTML: String

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

func makeLearningAttemptFixture(lessons: [String]) throws -> LearningAttemptFixture {
  let root = try makeEvaluationTestRoot()
  let artifacts = root.appendingPathComponent("learning-attempt-artifacts", isDirectory: true)
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  let beforeHTML = "<main id=\"before_html_unique\">Before page.</main>"
  let afterHTML = "<main id=\"after_html_unique\">After page.</main>"
  let task: [String: Any] = [
    "after_html": afterHTML,
    "before_html": beforeHTML,
    "region_ids": ["header", "content"],
  ]
  let lessonSet: [String: Any] = [
    "lessons": lessons,
    "schema_version": 1,
  ]
  let lessonSetData = try EvaluationCanonicalJSON.data(fromJSONObject: lessonSet)
  let carrierData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "active_lessons": lessonSet,
    "schema_version": 1,
    "task": task,
    "task_id": "page-000000000001",
  ])
  let carrierURL = artifacts.appendingPathComponent("carrier.json")
  try carrierData.write(to: carrierURL)
  let hasLessons = lessons.isEmpty == false
  let configured = try makeEvaluationConfiguration(
    root: root,
    executionProfile: .scheduledLearningV1,
    carrierPath: carrierURL.path,
    carrierSHA256: SHA256Digest.hex(carrierData),
    attemptID: hasLessons ? "learning-nonempty" : "learning-clean",
    split: hasLessons ? "regression" : "development",
    stage: hasLessons ? "regression" : "development",
    condition: hasLessons ? .lessonConditioned : .clean,
    lessonSource: hasLessons ? .artifact : .clean,
    activeLessons: lessonSet,
    task: task,
    inputSHA256: SHA256Digest.hex(carrierData),
    lessonSetDigestOverride: SHA256Digest.hex(lessonSetData)
  )
  let lessonSetText = try #require(String(data: lessonSetData, encoding: .utf8))
  return LearningAttemptFixture(
    root: root,
    configuration: configured.configuration,
    lessonSetText: lessonSetText,
    beforeHTML: beforeHTML,
    afterHTML: afterHTML
  )
}

private func runLearningAttempt(
  _ fixture: LearningAttemptFixture,
  provider: SequenceProvider,
  memoryStore: any MemoryStore = EvaluationMemoryStoreFixture(items: [])
) async throws -> EvaluationAttemptResult {
  try await runAttempt(
    configuration: fixture.configuration,
    provider: provider,
    memoryStore: memoryStore
  )
}

private func runAttempt(
  configuration: EvaluationAttemptConfiguration,
  provider: SequenceProvider,
  memoryStore: any MemoryStore
) async throws -> EvaluationAttemptResult {
  let roster = ProviderRoster(
    primary: LLMRouteBinding(
      provider: provider,
      wireModel: PageEvaluationContract.wireModel,
      configuredReference: PageEvaluationContract.providerReference,
      costPolicy: .includedPlan,
      reservationPolicy: .chatGPTReplayState
    )
  )
  return try await EvaluationAttemptRunner(
    roster: roster,
    httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([])),
    memoryStore: memoryStore
  ).run(
    configuration: configuration,
    sendBudget: EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )
  )
}

private func labeledFences(in request: ChatRequest, label: String) throws -> [String] {
  let escapedLabel = NSRegularExpression.escapedPattern(for: label)
  let pattern =
    #"<claw-untrusted nonce="([0-9a-f]{32})" label=""# + escapedLabel
    + #"">\n([\s\S]*?)\n</claw-untrusted nonce="\1">"#
  let expression = try NSRegularExpression(pattern: pattern)
  return request.messages.flatMap { message in
    let text = message.content.text
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      Range(match.range(at: 2), in: text).map { contentRange in
        String(text[contentRange])
      }
    }
  }
}

private func canonicalObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: EvaluationCanonicalJSON.data(encoding: value))
      as? [String: Any]
  )
}

private func memoryItem(id: Int64, text: String, sensitivity: Sensitivity) -> MemoryItem {
  MemoryItem(
    id: id,
    text: text,
    kind: .project,
    sensitivity: sensitivity,
    importance: .high,
    source: .owner,
    sessionId: nil,
    createdAt: Date(timeIntervalSince1970: Double(id))
  )
}

private final class EvaluationMemoryStoreFixture: MemoryStore, @unchecked Sendable {
  private let items: [MemoryItem]

  init(items: [MemoryItem]) {
    self.items = items
  }

  func append(_ newItem: NewMemoryItem, now: Date) throws(StoreError) -> MemoryItem {
    throw StoreError.unexpected("not used")
  }

  func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] {
    []
  }

  func get(id: Int64) throws(StoreError) -> MemoryItem? {
    nil
  }

  func delete(id: Int64) throws(StoreError) -> Bool {
    false
  }

  func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem] {
    Array(items.prefix(limit))
  }
}
