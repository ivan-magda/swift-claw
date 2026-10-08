import Foundation
import Testing

@testable import ClawCore

@Suite
struct JournalValueTests {
  @Test(arguments: ["2026-02-29", "2026-04-31", "2026-1-01", "../2026-01-01", "0000-01-01"])
  func rejectsInvalidDayIncludingDecodedValues(_ date: String) throws {
    // given
    let encoded = try JSONEncoder().encode(date)

    // when / then
    #expect(JournalDay(isoDate: date) == nil)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(JournalDay.self, from: encoded)
    }
  }

  @Test
  func sourceDayUsesTheAdmittedZoneAndCalendarYesterday() throws {
    // given — the first hour after the 23-hour DST day in New York.
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let instant = Date(timeIntervalSince1970: 1_741_579_200)  // 2025-03-10 04:00 UTC.

    // when
    let day = JournalDay.containing(instant, timeZone: zone)
    let yesterday = day.previous(in: zone)

    // then
    #expect(day.isoDate == "2025-03-10")
    let beforeLocalMidnight = instant.addingTimeInterval(-1)
    #expect(JournalDay.containing(beforeLocalMidnight, timeZone: zone).isoDate == "2025-03-09")
    #expect(JournalDay.containing(beforeLocalMidnight, timeZone: .gmt).isoDate == "2025-03-10")
    #expect(yesterday.isoDate == "2025-03-09")
    let leapDay = try JSONDecoder().decode(JournalDay.self, from: Data("\"2024-02-29\"".utf8))
    #expect(leapDay.isoDate == "2024-02-29")
  }

  @Test
  func disabledPolicyRetainsInspectionOwnerButNeverAdmitsCapture() {
    // given
    let policy = JournalPolicy(enabled: false, ownerUserID: 42, timeZoneID: "UTC")
    let invalid = JournalPolicy(enabled: true, ownerUserID: 0, timeZoneID: "UTC")

    // when / then
    #expect(policy.ownerUserID == 42)
    #expect(policy.scope == nil)
    #expect(invalid.scope == nil)
  }

  @Test(arguments: [
    "assistant",
    "proposal",
    "evidenceName",
    "evidenceDetail",
    "publicationURL",
    "evidenceCount",
  ])
  func rejectsIndependentPayloadBounds(_ field: String) throws {
    // given
    let scope = JournalScope(ownerUserID: 42, timeZoneID: "UTC")
    let day = try #require(JournalDay(isoDate: "2026-10-08"))

    // when / then
    #expect(throws: JournalValueError.self) {
      let proposal = try JournalProposal(
        sourceID: "message:41",
        text: String(
          repeating: "p",
          count: field == "proposal"
            ? JournalLimits.proposalGraphemes + 1 : 1
        )
      )
      let evidence = try JournalEvidence(
        outcome: field == "publicationURL"
          ? .publication(
            .confirmed(
              url: String(repeating: "u", count: JournalLimits.evidenceFieldGraphemes + 1)
            )
          ) : .workerReportedChecks,
        jobID: nil,
        name: String(
          repeating: "n",
          count: field == "evidenceName"
            ? JournalLimits.evidenceFieldGraphemes + 1 : 1
        ),
        detail: String(
          repeating: "d",
          count: field == "evidenceDetail"
            ? JournalLimits.evidenceFieldGraphemes + 1 : 1
        )
      )
      _ = try JournalSource(
        id: "message:42",
        scope: scope,
        sessionID: 7,
        occurredAt: Date(timeIntervalSince1970: 0),
        day: day,
        ownerText: "Owner",
        assistantText: String(
          repeating: "a",
          count:
            field == "assistant" ? JournalLimits.assistantTextGraphemes + 1 : 1
        ),
        supportingProposal: proposal,
        coderJobID: nil,
        evidence: Array(
          repeating: evidence,
          count: field == "evidenceCount"
            ? JournalLimits.evidenceEntries + 1 : 1
        )
      )
    }
  }

  @Test(arguments: ["owner", "proposal", "evidence"])
  func durableDecodeRechecksSourceBounds(_ field: String) throws {
    // given — a stored record whose source text has been enlarged outside the constructor.
    let source = try JournalSource(
      id: "message:42",
      scope: JournalScope(ownerUserID: 42, timeZoneID: "UTC"),
      sessionID: 7,
      occurredAt: Date(timeIntervalSince1970: 0),
      day: #require(JournalDay(isoDate: "2026-10-08")),
      ownerText: "Owner",
      assistantText: "Answer",
      supportingProposal: JournalProposal(sourceID: "message:41", text: "Proposal"),
      coderJobID: nil,
      evidence: [
        JournalEvidence(
          outcome: .workerReportedChecks,
          jobID: nil,
          name: "Checks",
          detail: "Passed"
        ),
      ]
    )
    let encoded = try JSONEncoder().encode(source)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    switch field {
    case "proposal":
      var proposal = try #require(object["supportingProposal"] as? [String: Any])
      proposal["text"] = String(repeating: "p", count: JournalLimits.proposalGraphemes + 1)
      object["supportingProposal"] = proposal
    case "evidence":
      var evidence = try #require(object["evidence"] as? [[String: Any]])
      evidence[0]["detail"] = String(
        repeating: "d",
        count: JournalLimits.evidenceFieldGraphemes + 1
      )
      object["evidence"] = evidence
    default:
      object["ownerText"] = String(repeating: "a", count: JournalLimits.ownerTextGraphemes + 1)
    }
    let enlarged = try JSONSerialization.data(withJSONObject: object)

    // when / then
    #expect(throws: JournalValueError.self) {
      _ = try JSONDecoder().decode(JournalSource.self, from: enlarged)
    }
  }

  @Test(arguments: ["message:0", "message:not-an-id", "coder:not-a-uuid", "arbitrary:42"])
  func rejectsUnrecognizedSourceIdentity(_ id: String) throws {
    // given
    let scope = JournalScope(ownerUserID: 42, timeZoneID: "UTC")
    let day = try #require(JournalDay(isoDate: "2026-10-08"))

    // when / then
    #expect(throws: JournalValueError.invalidSourceID) {
      _ = try JournalSource(
        id: id,
        scope: scope,
        sessionID: 7,
        occurredAt: Date(timeIntervalSince1970: 0),
        day: day,
        ownerText: "Owner",
        assistantText: "Answer",
        supportingProposal: nil,
        coderJobID: nil,
        evidence: []
      )
    }
  }

  @Test
  func sourceRejectsOverlongTextAndSerializedByteOverflow() throws {
    // given
    let scope = JournalScope(ownerUserID: 42, timeZoneID: "UTC")
    let day = try #require(JournalDay(isoDate: "2026-10-08"))
    let overlong = String(repeating: "я", count: JournalLimits.ownerTextGraphemes + 1)
    let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 70_000)
    let jobID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))

    // when
    let capped = try JournalSource(
      id: "coder:\(jobID)",
      scope: scope,
      sessionID: 7,
      occurredAt: Date(timeIntervalSince1970: 0),
      day: day,
      ownerText: String(repeating: "я", count: JournalLimits.ownerTextGraphemes),
      assistantText: String(repeating: "🙂", count: JournalLimits.assistantTextGraphemes),
      supportingProposal: JournalProposal(
        sourceID: "message:41",
        text: String(repeating: "p", count: JournalLimits.proposalGraphemes)
      ),
      coderJobID: jobID,
      evidence: Array(
        repeating: JournalEvidence(
          outcome: .workerReportedChecks,
          jobID: nil,
          name: String(repeating: "n", count: JournalLimits.evidenceFieldGraphemes),
          detail: String(repeating: "d", count: JournalLimits.evidenceFieldGraphemes)
        ),
        count: JournalLimits.evidenceEntries
      )
    )
    let decoded = try JSONDecoder().decode(JournalSource.self, from: JSONEncoder().encode(capped))

    // then
    #expect(decoded == capped)
    for text in [overlong, oversizedGrapheme] {
      #expect(throws: JournalValueError.self) {
        _ = try JournalSource(
          id: "message:42",
          scope: scope,
          sessionID: 7,
          occurredAt: Date(timeIntervalSince1970: 0),
          day: day,
          ownerText: text,
          assistantText: "Answer",
          supportingProposal: nil,
          coderJobID: nil,
          evidence: []
        )
      }
    }
  }
}
