import ClawCore
import Testing

@testable import ClawLLM

/// One configured-key shape and the authorization it must produce. A source that leaks a blank key
/// into either the header map or the redaction list is visibly wrong here.
struct BearerCase: Sendable, CustomTestStringConvertible {
  let scenario: String
  let bearer: String?
  let expectedHeaders: [String: String]
  let expectedRedactionValues: [String]

  var testDescription: String { scenario }
}

@Suite struct StaticLLMCredentialSourceTests {
  // MARK: - Authorization

  @Test(arguments: [
    BearerCase(
      scenario: "a configured key authorizes with a bearer",
      bearer: "sk-test-value",
      expectedHeaders: ["Authorization": "Bearer sk-test-value"],
      expectedRedactionValues: ["sk-test-value"]
    ),
    BearerCase(
      scenario: "no key at all keeps a local server working",
      bearer: nil,
      expectedHeaders: [:],
      expectedRedactionValues: []
    ),
    BearerCase(
      scenario: "an empty key is no key",
      bearer: "",
      expectedHeaders: [:],
      expectedRedactionValues: []
    ),
    BearerCase(
      scenario: "a blank key is no key",
      bearer: "   ",
      expectedHeaders: [:],
      expectedRedactionValues: []
    ),
  ])
  func theSourceEitherAuthorizesWithABearerOrWithNothing(sample: BearerCase) async throws {
    // given
    let source = StaticLLMCredentialSource(bearer: sample.bearer)

    // when
    let authorization = try await source.authorization()

    // then
    #expect(authorization.headers == sample.expectedHeaders)
    #expect(authorization.redactionValues == sample.expectedRedactionValues)
    #expect(authorization.generation == .zero)
  }

  // MARK: - Lifecycle

  @Test(arguments: [LLMCredentialRejection.refresh, .authenticationRequired])
  func rejectionNeitherRotatesTheKeyNorLatchesTheSource(
    disposition: LLMCredentialRejection
  ) async throws {
    // given
    let source = StaticLLMCredentialSource(bearer: "sk-test-value")
    let before = try await source.authorization()

    // when
    await source.reject(generation: before.generation, disposition: disposition)

    // then
    let after = try await source.authorization()
    #expect(after == before)
  }

  @Test func shutdownNeitherThrowsNorRevokesAuthorization() async throws {
    // given
    let source = StaticLLMCredentialSource(bearer: "sk-test-value")
    let before = try await source.authorization()

    // when
    try await source.shutdown()

    // then
    let after = try await source.authorization()
    #expect(after == before)
  }
}
