import Foundation
import Logging

/// Developer-facing logging setup for the daemon. This is the runtime diagnostic stream
/// (`stdout` via swift-log), deliberately separate from the durable `audit_events` trail: audit is
/// the business/security record, these logs are for watching the request lifecycle in local dev.
///
/// Verbosity is controlled by the `CLAW_LOG_LEVEL` environment variable (swift-log level raw
/// values); absent or unrecognized falls back to `.info`. Every line is passed through a secret
/// redactor before it is written, so an accidental `\(error)` that embeds the bot token or an API
/// key can never leak.
public enum DeveloperLogging {
  /// Overrides the developer-log verbosity. Values are swift-log `Logger.Level` raw values:
  /// `trace | debug | info | notice | warning | error | critical`. Absent/unrecognized ⇒ `.info`.
  public static let levelEnvKey = "CLAW_LOG_LEVEL"

  /// Parses a `CLAW_LOG_LEVEL` value into a level, defaulting to `.info` for absent, blank, or
  /// unrecognized input (a typo must never silence logging).
  public static func level(from raw: String?) -> Logger.Level {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

    guard !trimmed.isEmpty else {
      return .info
    }

    return Logger.Level(rawValue: trimmed) ?? .info
  }

  /// Installs the process-wide swift-log backend: a ``RedactingLogHandler`` over `stdout` at
  /// `level`. Call exactly once, before the first `Logger` is constructed. `redact` is applied to
  /// every message and string metadata value — wire `SecretRedactor.redact` here.
  public static func bootstrap(
    level: Logger.Level,
    redact: @escaping @Sendable (String) -> String
  ) {
    LoggingSystem.bootstrap { label in
      var handler = RedactingLogHandler(
        base: StreamLogHandler.standardOutput(label: label),
        redact: redact
      )
      handler.logLevel = level
      return handler
    }
  }
}

/// A `LogHandler` decorator that scrubs known secret values from EVERY channel the wrapped handler
/// can render — the message, per-call and persistent metadata values, a `metadataProvider`'s output,
/// and a structured `error` — before delegating. It is the single choke-point that keeps the bot
/// token / API keys out of developer logs, including any accidental `\(error)` interpolation at
/// existing call sites. The durable audit trail does not flow through swift-log and is unaffected.
struct RedactingLogHandler: LogHandler {
  private var base: any LogHandler
  private let redact: @Sendable (String) -> String

  init(base: any LogHandler, redact: @escaping @Sendable (String) -> String) {
    self.base = base
    self.redact = redact
  }

  func log(event: LogEvent) {
    var metadata = event.metadata.map { Self.redacted($0, using: redact) } ?? [:]

    if let error = event.error {
      // `StreamLogHandler` renders `event.error` into these two keys. Do it here (redacted) and pass
      // `error: nil` downstream, so the detail survives without a second, unredacted render.
      metadata["error.message"] = .string(redact("\(error)"))
      metadata["error.type"] = .string("\(String(reflecting: type(of: error)))")
    }

    base.log(
      event: LogEvent(
        level: event.level,
        message: Logger.Message(stringLiteral: redact(event.message.description)),
        metadata: metadata.isEmpty ? nil : metadata,
        source: event.source,
        file: event.file,
        function: event.function,
        line: event.line
      )
    )
  }

  var logLevel: Logger.Level {
    get { base.logLevel }
    set { base.logLevel = newValue }
  }

  // Persistent metadata and the provider are merged by the base handler AFTER `log(event:)` runs, so
  // they are redacted here at ingress instead — otherwise a secret stamped via `logger[metadataKey:]`
  // or surfaced by a `metadataProvider` would reach stdout unscrubbed.
  var metadata: Logger.Metadata {
    get { base.metadata }
    set { base.metadata = Self.redacted(newValue, using: redact) }
  }

  var metadataProvider: Logger.MetadataProvider? {
    get { base.metadataProvider }
    set {
      let redact = self.redact
      base.metadataProvider = newValue.map { provider in
        Logger.MetadataProvider { Self.redacted(provider.get(), using: redact) }
      }
    }
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { base[metadataKey: key] }
    set { base[metadataKey: key] = newValue.map { Self.redacted($0, using: redact) } }
  }

  private static func redacted(
    _ metadata: Logger.Metadata,
    using redact: (String) -> String
  ) -> Logger.Metadata {
    metadata.mapValues { redacted($0, using: redact) }
  }

  private static func redacted(
    _ value: Logger.MetadataValue,
    using redact: (String) -> String
  ) -> Logger.MetadataValue {
    switch value {
    case .string(let text):
      .string(redact(text))
    case .stringConvertible(let convertible):
      .string(redact("\(convertible)"))
    case .array(let values):
      .array(values.map { redacted($0, using: redact) })
    case .dictionary(let nested):
      .dictionary(redacted(nested, using: redact))
    }
  }
}
