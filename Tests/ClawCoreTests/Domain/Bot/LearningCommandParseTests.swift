import Testing

@testable import ClawCore

@Suite
struct LearningCommandParseTests {
  @Test(arguments: [
    ("/learning", Command.learning(.list)),
    ("/learning list", .learning(.list)),
    ("/learning LIST", .learning(.list)),
    ("/LEARNING@CLAW_BOT list", .learning(.list)),
    ("/learning 3", .learning(.detail(jobID: 3))),
    ("/learning reset 3", .learning(.reset(jobID: 3))),
    ("/learning RESET 3", .learning(.reset(jobID: 3))),
    ("/learning reset", .learning(.reset(jobID: nil))),
    ("/learning reset 0", .learning(.reset(jobID: nil))),
    ("/learning reset junk", .learning(.reset(jobID: nil))),
    ("/learning reset 3 extra", .learning(.reset(jobID: nil))),
    ("/learning bogus", .learning(.list)),
    ("/learning 0", .learning(.list)),
    ("/learning -1", .learning(.list)),
  ])
  func grammar(text: String, expected: Command) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then — ignoring the argument tail collapses detail/reset into the list branch.
    #expect(command == expected)
  }

  @Test(arguments: ["please /learning", " /learning", "/learning@some_other_bot"])
  func nonLeadingOrMismatchedCommandsStayPlain(text: String) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then — parsing a non-authoritative slash token turns ordinary text into a control request.
    #expect(command == .plain(text))
  }
}
