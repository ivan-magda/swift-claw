import ClawCore
import Testing

@Suite
struct JournalCommandTests {
  @Test
  func parsesJournalDatesAndRejectsInvalidDates() throws {
    // given
    let day = try #require(JournalDay(isoDate: "2026-10-08"))

    // when / then
    #expect(Command.parse("/journal", botUsername: nil) == .journal(.status))
    #expect(Command.parse("/journal show 2026-10-08", botUsername: nil) == .journal(.show(day)))
    #expect(Command.parse("/journal delete 2026-10-08", botUsername: nil) == .journal(.delete(day)))
    for arguments in ["show 2026-02-30", "delete ../MEMORY.md", "show", "delete 2026-10-08 extra"] {
      #expect(Command.parse("/journal \(arguments)", botUsername: nil) == .journal(.invalid))
    }
    #expect(Command.journal(.status).isDirectOnly)
  }
}
