import Foundation

public enum JournalLimits {
  public static let ownerTextGraphemes = 4_000
  public static let assistantTextGraphemes = 8_000
  public static let proposalGraphemes = 2_000
  public static let evidenceEntries = 16
  public static let evidenceFieldGraphemes = 400
  public static let storedSourceBytes = 128 * 1024
  public static let requestBytes = 512 * 1024
  public static let inputTokens = 24_000
  public static let outputTokens = 3_072
  public static let notes = 20
  public static let noteGraphemes = 400
  public static let totalNoteGraphemes = 4_096
  public static let inferenceDeadlineSeconds = 30
  public static let startedCallsPerUTCDay = 24
  public static let pendingAgeSeconds = 48 * 60 * 60
  public static let sweepCandidates = 100
  public static let sweepIntervalSeconds = 60
  public static let batchSources = 10
  public static let dayFileBytes = 512 * 1024
  public static let contextGraphemes = 4_000
  public static let fittedOwnerTextGraphemes = 2_000
  public static let fittedAssistantTextGraphemes = 4_000
}

public struct JournalScope: Codable, Sendable, Equatable, Hashable {
  public let ownerUserID: Int64
  public let timeZoneID: String

  public init(ownerUserID: Int64, timeZoneID: String) {
    self.ownerUserID = ownerUserID
    self.timeZoneID = timeZoneID
  }
}

public struct JournalPolicy: Sendable, Equatable {
  public let enabled: Bool
  public let ownerUserID: Int64?
  public let timeZoneID: String

  public init(enabled: Bool, ownerUserID: Int64?, timeZoneID: String) {
    self.enabled = enabled
    self.ownerUserID = ownerUserID
    self.timeZoneID = timeZoneID
  }

  public var scope: JournalScope? {
    guard enabled, let ownerUserID, ownerUserID > 0 else {
      return nil
    }
    return JournalScope(ownerUserID: ownerUserID, timeZoneID: timeZoneID)
  }
}

public struct JournalDay: Sendable, Equatable, Hashable, Codable {
  public let isoDate: String

  public init?(isoDate: String) {
    let bytes = Array(isoDate.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else {
      return nil
    }
    for index in bytes.indices where index != 4 && index != 7 {
      guard (48...57).contains(bytes[index]) else {
        return nil
      }
    }

    let parts = isoDate.split(separator: "-").compactMap {
      Int($0)
    }
    guard parts[0] > 0 else {
      return nil
    }
    let calendar = Self.calendar(in: .gmt)
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard let instant = calendar.date(from: components),
          calendar.dateComponents([.year, .month, .day], from: instant) == components
    else {
      return nil
    }
    self.isoDate = isoDate
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let day = Self(isoDate: text) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid journal day")
    }
    self = day
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(isoDate)
  }

  public static func containing(_ instant: Date, timeZone: TimeZone) -> JournalDay {
    let calendar = Self.calendar(in: timeZone)
    let components = calendar.dateComponents([.year, .month, .day], from: instant)
    guard let year = components.year, let month = components.month, let day = components.day,
          let journalDay = JournalDay(isoDate: String(format: "%04d-%02d-%02d", year, month, day))
    else {
      preconditionFailure("The instant cannot be represented as a journal day")
    }
    return journalDay
  }

  public func previous(in timeZone: TimeZone) -> JournalDay {
    let calendar = Self.calendar(in: timeZone)
    let parts = isoDate.split(separator: "-").compactMap {
      Int($0)
    }
    // Noon avoids midnight transitions; calendar arithmetic also handles 23/25-hour days.
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
    guard let instant = calendar.date(from: components),
          let previous = calendar.date(byAdding: .day, value: -1, to: instant)
    else {
      preconditionFailure("The validated journal day must support calendar arithmetic")
    }
    return Self.containing(previous, timeZone: timeZone)
  }
}

public struct JournalExchangeAdmission: Codable, Sendable, Equatable {
  public let scope: JournalScope
  public let sourceTimestamp: Date
  public let sourceDay: JournalDay

  public init(scope: JournalScope, sourceTimestamp: Date, sourceDay: JournalDay) {
    self.scope = scope
    self.sourceTimestamp = sourceTimestamp
    self.sourceDay = sourceDay
  }
}

// MARK: - Calendar

private extension JournalDay {
  static func calendar(in timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }
}
