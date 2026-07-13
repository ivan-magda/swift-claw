import ClawCore
import ClawTools
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct DeveloperLoggingTests {
  @Test func levelDefaultsToInfoWhenAbsentBlankOrUnrecognized() {
    // given / when / then
    #expect(DeveloperLogging.level(from: nil) == .info)
    #expect(DeveloperLogging.level(from: "") == .info)
    #expect(DeveloperLogging.level(from: "   ") == .info)
    #expect(DeveloperLogging.level(from: "verbose") == .info)
  }

  @Test func levelParsesSwiftLogRawValuesCaseInsensitively() {
    // given / when / then
    #expect(DeveloperLogging.level(from: "debug") == .debug)
    #expect(DeveloperLogging.level(from: "DEBUG") == .debug)
    #expect(DeveloperLogging.level(from: " Trace ") == .trace)
    #expect(DeveloperLogging.level(from: "warning") == .warning)
    #expect(DeveloperLogging.level(from: "critical") == .critical)
  }

  @Test func redactsSecretInterpolatedIntoMessage() {
    // given
    let secret = "1234567:AA-super-secret-bot-token"
    let capture = CaptureBox()
    let logger = Self.redactingLogger(secret: secret, into: capture)

    // when
    logger.error("telegram send failed: transport(\(secret))")

    // then
    let line = capture.messages.last ?? ""
    #expect(!line.contains(secret))
    #expect(line.contains(SecretRedactor.replacement))
  }

  @Test func redactsSecretInStringMetadataValue() {
    // given
    let secret = "sk-live-abcdef-api-key"
    let capture = CaptureBox()
    let logger = Self.redactingLogger(secret: secret, into: capture)

    // when
    logger.info("fetch done", metadata: ["url": .string("https://api.example/\(secret)/v1")])

    // then
    let rendered = capture.metadatas.last.map { "\($0)" } ?? ""
    #expect(!rendered.contains(secret))
    #expect(rendered.contains(SecretRedactor.replacement))
  }

  @Test func passesThroughNonSecretContentUnchanged() {
    // given
    let capture = CaptureBox()
    let logger = Self.redactingLogger(secret: "unused-secret", into: capture)

    // when
    logger.info("turn finished outcome=completed tokens=1200 usd=0.004")

    // then
    #expect(capture.messages.last == "turn finished outcome=completed tokens=1200 usd=0.004")
  }

  @Test func redactsSecretSetAsPersistentMetadata() {
    // given — a secret stamped via the persistent-metadata subscript (merged by the base handler,
    // so it must be scrubbed at ingress, not in log(event:)).
    let secret = "1234:AA-persistent-token"
    let redactor = SecretRedactor(secretValues: [secret])
    var handler = RedactingLogHandler(
      base: CapturingLogHandler(box: CaptureBox()),
      redact: { redactor.redact($0) }
    )

    // when
    handler[metadataKey: "authorization"] = .string("Bearer \(secret)")

    // then — reading it back reflects what was stored on the base handler.
    let stored = handler[metadataKey: "authorization"].map { "\($0)" } ?? ""
    #expect(!stored.contains(secret))
    #expect(stored.contains(SecretRedactor.replacement))
  }

  @Test func redactsSecretCarriedByStructuredError() {
    // given
    let secret = "sk-live-error-embedded-key"
    let redactor = SecretRedactor(secretValues: [secret])
    let capture = CaptureBox()
    let handler = RedactingLogHandler(
      base: CapturingLogHandler(box: capture),
      redact: { redactor.redact($0) }
    )

    // when — a structured error whose description embeds a secret.
    handler.log(
      event: LogEvent(
        level: .error,
        message: "store write failed",
        error: FakeSecretError(detail: secret),
        metadata: nil,
        source: "test",
        file: #fileID,
        function: #function,
        line: #line
      )
    )

    // then — the base handler receives the error only as redacted metadata.
    let rendered = capture.metadatas.last.map { "\($0)" } ?? ""
    #expect(!rendered.contains(secret))
    #expect(rendered.contains(SecretRedactor.replacement))
  }

  private static func redactingLogger(secret: String, into capture: CaptureBox) -> Logger {
    let redactor = SecretRedactor(secretValues: [secret])
    var logger = Logger(label: "test") { _ in
      RedactingLogHandler(base: CapturingLogHandler(box: capture), redact: { redactor.redact($0) })
    }
    logger.logLevel = .trace
    return logger
  }
}

private struct FakeSecretError: Error, CustomStringConvertible {
  let detail: String
  var description: String { "write failed: \(detail)" }
}

/// Thread-safe sink so the test can read back what the wrapped handler received post-redaction.
private final class CaptureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var messageLog: [String] = []
  private var metadataLog: [Logger.Metadata] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return messageLog
  }

  var metadatas: [Logger.Metadata] {
    lock.lock()
    defer { lock.unlock() }
    return metadataLog
  }

  func record(message: String, metadata: Logger.Metadata?) {
    lock.lock()
    defer { lock.unlock() }
    messageLog.append(message)
    metadataLog.append(metadata ?? [:])
  }
}

private struct CapturingLogHandler: LogHandler {
  let box: CaptureBox
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    box.record(message: event.message.description, metadata: event.metadata)
  }
}
