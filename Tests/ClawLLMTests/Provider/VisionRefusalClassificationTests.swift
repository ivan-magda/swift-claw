import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawLLM

/// The refusal a provider returns when the configured model cannot see. It carries a null `code`, so
/// the message text is the only discriminator; these tests pin how narrow the match is, because a
/// false positive would tell the owner to change models over an unrelated failure.
@Suite struct VisionRefusalClassificationTests {
  /// The observed OpenAI shape: `invalid_request_error`, a null code, and the offending content-part
  /// type named in the message.
  private static let openAIRefusalBody = """
    {"error":{"message":"Invalid content type. image_url is only supported by certain models.",\
    "type":"invalid_request_error","param":null,"code":null}}
    """

  @Test func recognisesTheOpenAiVisionRefusal() {
    // given
    let body = Self.openAIRefusalBody

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 400, body: body)

    // then
    #expect(matched)
  }

  @Test func recognisesTheResponsesRouteContentPartName() {
    // given — the managed route names the part `input_image` rather than `image_url`
    let body = """
      {"error":{"message":"Invalid value: 'input_image'. This model does not support image inputs.",\
      "type":"invalid_request_error","param":"input","code":null}}
      """

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 400, body: body)

    // then
    #expect(matched)
  }

  @Test func doesNotMisreadAnUnrelatedBadRequest() {
    // given
    let body = """
      {"error":{"message":"Unsupported parameter: 'stop'.","type":"invalid_request_error"}}
      """

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 400, body: body)

    // then
    #expect(matched == false)
  }

  @Test func ignoresNonBadRequestStatuses() {
    // given — a 500 mentioning images is an outage, not a capability answer
    let body = """
      {"error":{"message":"image_url processing failed","type":"server_error"}}
      """

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 500, body: body)

    // then
    #expect(matched == false)
  }

  @Test func ignoresTheRefusalTextItselfOnANonBadRequestStatus() {
    // given — byte-for-byte the refusal body, arriving on a status that means the server broke
    let body = Self.openAIRefusalBody

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 503, body: body)

    // then — the status guard alone must reject this; without it an outage would read as a
    // capability answer
    #expect(matched == false)
  }

  @Test func ignoresABadRequestOfAnotherErrorTypeThatQuotesAnImagePart() {
    // given — an image part named inside a body that is not an invalid-request rejection
    let body = """
      {"error":{"message":"Rate limit reached while processing image_url parts.",\
      "type":"rate_limit_error","code":null}}
      """

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 400, body: body)

    // then — the error-type guard alone must reject this
    #expect(matched == false)
  }

  @Test func toleratesAMalformedBody() {
    // given — classification must never throw on a body it cannot parse
    let body = "not json"

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 400, body: body)

    // then
    #expect(matched == false)
  }

  @Test func toleratesABodyThatIsNotText() {
    // given — a diagnostic that is not valid UTF-8 at all
    let body = Data([0xff, 0xfe, 0xfd])

    // when
    let matched = ProviderErrorClassifier.isVisionRefusal(status: 400, body: body)

    // then
    #expect(matched == false)
  }
}

/// The refusal must reach the runtime as a distinct, text-free provider cause on both of the Chat
/// Completions adapter's execution paths, so the owner reply can name it.
@Suite struct VisionRefusalProviderMappingTests {
  private static let refusalBody = Data(
    """
    {"error":{"message":"Invalid content type. image_url is only supported by certain models.",\
    "type":"invalid_request_error","param":null,"code":null}}
    """.utf8
  )

  @Test func bufferedCompletionRaisesVisionUnsupported() async throws {
    // given
    let exec = ScriptedHTTPExecutor([
      .ok(HTTPResult(statusCode: 400, headers: [:], body: Self.refusalBody))
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    var thrown: (any Error)?
    do {
      _ = try await provider.complete(request: sampleRequest)
    } catch {
      thrown = error
    }

    // then — a clean 400 head proves nothing was generated, so nothing is debited either
    let failure = try #require(thrown as? ProviderFailure)
    #expect(failure.cause == .visionUnsupported)
    #expect(failure.accounting == .notStarted)
    #expect(await exec.recorded.count == 1)
  }

  @Test func streamingRaisesVisionUnsupported() async throws {
    // given
    let exec = ScriptedHTTPExecutor([
      .stream(HTTPStreamHead(statusCode: 400, headers: [:]), [Self.refusalBody])
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (_, thrown, terminal) = await drain(provider.stream(request: sampleRequest))

    // then
    #expect(
      terminal == .failed(ProviderFailure(cause: .visionUnsupported, accounting: .notStarted))
    )
    #expect((thrown as? ProviderFailure)?.cause == .visionUnsupported)
  }

  @Test func anUnrelatedBadRequestStaysTheGenericTerminalFailure() async throws {
    // given
    let body = Data(
      #"{"error":{"message":"Unsupported parameter: 'stop'.","type":"invalid_request_error"}}"#.utf8
    )
    let exec = ScriptedHTTPExecutor([
      .ok(HTTPResult(statusCode: 400, headers: [:], body: body))
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    var thrown: (any Error)?
    do {
      _ = try await provider.complete(request: sampleRequest)
    } catch {
      thrown = error
    }

    // then — the additive discriminator never swallows the existing terminal path
    let failure = try #require(thrown as? ProviderFailure)
    #expect(failure.cause == .terminal(status: 400, message: "Unsupported parameter: 'stop'."))
  }
}
