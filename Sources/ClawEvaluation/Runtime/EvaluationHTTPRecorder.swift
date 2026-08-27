import ClawAuth
import ClawCore
import Foundation

struct EvaluationResponsesSend: Codable, Sendable, Equatable {
  package let sequence: Int
  package let requestedModel: String?
  package let bodyByteCount: Int
  package let bodySHA256: String
  package let normalizedStructureSHA256: String
  package let untrustedFencePresent: Bool
  package let untrustedPayloadSHA256: String?

  package init(
    sequence: Int,
    requestedModel: String?,
    bodyByteCount: Int,
    bodySHA256: String,
    normalizedStructureSHA256: String,
    untrustedFencePresent: Bool,
    untrustedPayloadSHA256: String? = nil
  ) {
    self.sequence = sequence
    self.requestedModel = requestedModel
    self.bodyByteCount = bodyByteCount
    self.bodySHA256 = bodySHA256
    self.normalizedStructureSHA256 = normalizedStructureSHA256
    self.untrustedFencePresent = untrustedFencePresent
    self.untrustedPayloadSHA256 = untrustedPayloadSHA256
  }

  enum CodingKeys: String, CodingKey {
    case sequence
    case requestedModel = "requested_model"
    case bodyByteCount = "body_byte_count"
    case bodySHA256 = "body_sha256"
    case normalizedStructureSHA256 = "normalized_structure_sha256"
    case untrustedFencePresent = "untrusted_fence_present"
    case untrustedPayloadSHA256 = "untrusted_payload_sha256"
  }
}

struct EvaluationHTTPSnapshot: Codable, Sendable, Equatable {
  package let responsesSends: [EvaluationResponsesSend]
  package let provenNotStartedResponsesSends: Int
  package let credentialHTTPCalls: Int
  package let integrityFailures: [String]

  package init(
    responsesSends: [EvaluationResponsesSend],
    provenNotStartedResponsesSends: Int = 0,
    credentialHTTPCalls: Int,
    integrityFailures: [String]
  ) {
    self.responsesSends = responsesSends
    self.provenNotStartedResponsesSends = provenNotStartedResponsesSends
    self.credentialHTTPCalls = credentialHTTPCalls
    self.integrityFailures = integrityFailures
  }
}

/// Records only safe request metadata and enforces the frozen wire model before the live transport.
/// OAuth refresh calls use `execute`; Responses inference sends use `openStream`, so the two budgets
/// remain separate without inspecting authorization headers or bodies that can contain user text.
actor EvaluationHTTPRecorder: HTTPExecuting, HTTPStreaming {
  private let base: any HTTPExecuting & HTTPStreaming
  private let expectedWireModel: String
  private let maximumResponsesSends: Int
  private let progressRecorder: EvaluationAttemptProgressRecorder?
  private let attemptID: String?
  private var sends: [EvaluationResponsesSend] = []
  private var provenNotStartedResponsesSends = 0
  private var credentialCalls = 0
  private var failures: [String] = []

  package init(
    base: any HTTPExecuting & HTTPStreaming,
    expectedWireModel: String = PageEvaluationContract.wireModel,
    maximumResponsesSends: Int = PageEvaluationContract.maximumResponsesSendsPerAttempt,
    progressRecorder: EvaluationAttemptProgressRecorder? = nil,
    attemptID: String? = nil
  ) {
    self.base = base
    self.expectedWireModel = expectedWireModel
    self.maximumResponsesSends = maximumResponsesSends
    self.progressRecorder = progressRecorder
    self.attemptID = attemptID
  }

  package func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    guard request.url != ChatGPTProviderMetadata.responsesURL else {
      failures.append("buffered_inference_forbidden")
      throw EvaluationHTTPError.bufferedInferenceForbidden
    }
    if let progressRecorder, let attemptID {
      do {
        try progressRecorder.recordCredentialHTTPCall(attemptID: attemptID)
      } catch {
        failures.append("progress_publication_failed")
        throw EvaluationHTTPError.progressPublicationFailed
      }
    }
    credentialCalls += 1
    return try await base.execute(request)
  }

  package func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    guard request.url == ChatGPTProviderMetadata.responsesURL else {
      failures.append("unexpected_stream_endpoint")
      throw EvaluationHTTPError.unexpectedStreamEndpoint
    }
    guard sends.count < maximumResponsesSends else {
      failures.append("responses_send_cap")
      throw EvaluationHTTPError.responsesSendCap
    }

    let requestedModel = Self.model(in: request.body)
    guard requestedModel == expectedWireModel else {
      failures.append("wire_model_mismatch")
      throw EvaluationHTTPError.wireModelMismatch
    }

    let untrustedPayload = Self.untrustedPayload(in: request.body)
    let recordedSend = EvaluationResponsesSend(
      sequence: sends.count + 1,
      requestedModel: requestedModel,
      bodyByteCount: request.body?.count ?? 0,
      bodySHA256: SHA256Digest.hex(request.body ?? Data()),
      normalizedStructureSHA256: Self.normalizedStructureSHA256(request.body),
      untrustedFencePresent: untrustedPayload != nil,
      untrustedPayloadSHA256: untrustedPayload.map { SHA256Digest.hex($0) }
    )
    if let progressRecorder, let attemptID {
      do {
        try progressRecorder.recordResponsesSend(attemptID: attemptID, request: recordedSend)
      } catch {
        failures.append("progress_publication_failed")
        throw EvaluationHTTPError.progressPublicationFailed
      }
    }
    sends.append(recordedSend)

    return try await base.openStream(request)
  }

  package func snapshot() -> EvaluationHTTPSnapshot {
    EvaluationHTTPSnapshot(
      responsesSends: sends,
      provenNotStartedResponsesSends: provenNotStartedResponsesSends,
      credentialHTTPCalls: credentialCalls,
      integrityFailures: failures
    )
  }

  package func recordProvenNotStartedResponsesSends(_ count: Int) throws {
    guard
      count >= 0,
      provenNotStartedResponsesSends + count <= sends.count
    else {
      failures.append("proven_not_started_send_count")
      throw EvaluationHTTPError.progressPublicationFailed
    }
    if let progressRecorder, let attemptID {
      do {
        try progressRecorder.recordProvenNotStartedResponsesSends(
          attemptID: attemptID,
          count: count
        )
      } catch {
        failures.append("progress_publication_failed")
        throw EvaluationHTTPError.progressPublicationFailed
      }
    }
    provenNotStartedResponsesSends += count
  }

  private static func model(in body: Data?) -> String? {
    guard
      let body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return nil
    }
    return object["model"] as? String
  }

  static func normalizedStructureSHA256(_ body: Data?) -> String {
    guard
      let body,
      let object = try? JSONSerialization.jsonObject(with: body),
      JSONSerialization.isValidJSONObject(object),
      let normalized = try? JSONSerialization.data(
        withJSONObject: normalize(object),
        options: [.sortedKeys]
      )
    else {
      return SHA256Digest.hex(body ?? Data())
    }
    return SHA256Digest.hex(normalized)
  }

  private static func untrustedPayload(in body: Data?) -> Data? {
    guard
      let body,
      let object = try? JSONSerialization.jsonObject(with: body)
    else {
      return nil
    }
    let pattern =
      #"<claw-untrusted nonce="([0-9a-f]{32})"(?: label="[^"]+")?>\n([\s\S]*)\n</claw-untrusted nonce="\1">"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    for value in strings(in: object) {
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      guard
        let match = expression.firstMatch(in: value, range: range),
        let contentRange = Range(match.range(at: 2), in: value)
      else {
        continue
      }
      return Data(value[contentRange].utf8)
    }
    return nil
  }

  private static func strings(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    if let array = value as? [Any] { return array.flatMap(strings) }
    if let object = value as? [String: Any] { return object.values.flatMap(strings) }
    return []
  }

  private static func normalize(_ value: Any) -> Any {
    if let string = value as? String {
      return string.replacingOccurrences(
        of: #"(<\/?claw-untrusted nonce=")[0-9a-f]{32}("(?: label="[^"]+")?>)"#,
        with: #"$1<fresh>$2"#,
        options: .regularExpression
      )
    }
    if let array = value as? [Any] {
      return array.map(normalize)
    }
    if let object = value as? [String: Any] {
      return object.mapValues(normalize)
    }
    return value
  }
}

enum EvaluationHTTPError: Error, Sendable, Equatable {
  case bufferedInferenceForbidden
  case unexpectedStreamEndpoint
  case responsesSendCap
  case wireModelMismatch
  case progressPublicationFailed
}
