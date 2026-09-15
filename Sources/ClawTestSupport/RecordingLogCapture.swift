import Logging
import Synchronization

/// A thread-safe swift-log sink for tests whose observable contract includes a developer log.
public final class RecordingLogCapture: Sendable {
  public struct Entry: Sendable {
    public let level: Logger.Level
    public let message: String
    public let metadata: Logger.Metadata
  }

  private let storage = Mutex<[Entry]>([])

  public init() {}

  public var entries: [Entry] {
    storage.withLock { current in
      current
    }
  }

  public func logger(label: String = "test.recording") -> Logger {
    Logger(label: label) { _ in
      RecordingLogHandler(capture: self)
    }
  }

  fileprivate func append(_ event: LogEvent) {
    storage.withLock { current in
      current.append(
        Entry(
          level: event.level,
          message: event.message.description,
          metadata: event.metadata ?? [:]
        )
      )
    }
  }
}

private struct RecordingLogHandler: LogHandler {
  let capture: RecordingLogCapture
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    capture.append(event)
  }
}
