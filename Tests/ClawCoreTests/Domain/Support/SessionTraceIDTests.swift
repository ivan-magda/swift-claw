import ClawCore
import Testing

@Suite struct SessionTraceIDTests {
  @Test(arguments: [
    (Int64(42), "clawd-session-42"),
    (Int64(0), "clawd-session-0"),
    (Int64(-1), "clawd-session--1"),
    (Int64.max, "clawd-session-9223372036854775807"),
    (Int64.min, "clawd-session--9223372036854775808"),
  ])
  func formatsTheDatabaseIdentityInDecimal(sessionID: Int64, expected: String) {
    // given / when / then
    #expect(SessionTraceID.format(sessionID: sessionID) == expected)
  }
}
