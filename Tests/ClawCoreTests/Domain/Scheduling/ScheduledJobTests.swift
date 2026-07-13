import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore

@Suite struct RecurrenceEnvelopeTests {
  private func weekdaySevenBerlinRule() throws -> Calendar.RecurrenceRule {
    // force_unwrapping is `error` project-wide with no Tests exclusion (.swiftlint.yml); #require
    // is the house pattern for a lookup that is statically known to succeed.
    SchedulingRuleFixtures.weekdaySeven(zone: try #require(TimeZone(identifier: "Europe/Berlin")))
  }

  @Test func roundTripIsByteForByteStable() throws {
    // given — the toolchain-drift tripwire (spec §17, preamble Verification Notes): if a future
    // Foundation changes the rule's encoding, this breaks BEFORE any stored row does.
    let envelope = RecurrenceEnvelope(
      schemaVersion: RecurrenceEnvelope.currentSchemaVersion,
      rule: try weekdaySevenBerlinRule()
    )

    // when
    let firstJSON = try envelope.encodedJSON()
    let decoded = try RecurrenceEnvelope.decode(fromJSON: firstJSON)
    let secondJSON = try decoded.encodedJSON()

    // then — byte-for-byte re-decodability, not merely value equality
    #expect(secondJSON == firstJSON)
    #expect(decoded == envelope)
    #expect(decoded.rule == envelope.rule)
  }

  @Test func envelopeUsesThePinnedStorageKeys() throws {
    // given
    let envelope = RecurrenceEnvelope(schemaVersion: 1, rule: try weekdaySevenBerlinRule())

    // when
    let json = try envelope.encodedJSON()
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

    // then — the stored wrapper is exactly {"schema_version":1,"rule":{…}} (spec D2)
    #expect(object?.keys.sorted() == ["rule", "schema_version"])
    #expect(object?["schema_version"] as? Int == 1)
  }
}

@Suite struct SchedulingDomainTests {
  @Test func statusRawValuesMatchTheDBVocabulary() {
    // given / when / then — the closed FSM vocabulary of spec §4.1
    #expect(ScheduledJobStatus.active.rawValue == "ACTIVE")
    #expect(ScheduledJobStatus.paused.rawValue == "PAUSED")
    #expect(ScheduledJobStatus.completed.rawValue == "COMPLETED")
    #expect(ScheduledJobStatus.cancelled.rawValue == "CANCELLED")
  }

  @Test func originRawValuesMatchTheRunsColumnVocabulary() {
    // given / when / then — the runs.origin discriminator of spec §4.2
    #expect(RunOrigin.interactive.rawValue == "interactive")
    #expect(RunOrigin.scheduled.rawValue == "scheduled")
    #expect(RunOrigin.heartbeat.rawValue == "heartbeat")
  }
}
