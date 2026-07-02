import Testing

@testable import ClawCore

@Suite struct CommandTests {
  @Test(arguments: [
    ("/start", Command.start),
    ("/START please", .start),
    ("/stop", .stop),
    ("/stop now", .stop),
    ("/new", .new),
    ("/new fresh please", .new),
    ("/stop@claw_bot", .stop),
    ("/STOP@CLAW_BOT now", .stop),
    ("/remember buy milk", .remember(.save(kind: .user, text: "buy milk"))),
    ("/REMEMBER@CLAW_BOT project: x", .remember(.save(kind: .project, text: "x"))),
    ("/remember", .remember(.invalid)),
    ("/memory", .memory(.review)),
    ("/memory show 3", .memory(.show(id: 3))),
    ("/MEMORY@CLAW_BOT project", .memory(.filter(kind: .project))),
  ])
  func leadingSlashCommandsParse(text: String, expected: Command) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then
    #expect(command == expected)
  }

  @Test(arguments: [
    "tell me about /stop",
    " /stop",
    "/stop@some_other_bot",
    "/remember@some_other_bot x",
    "/memory@some_other_bot",
    "/stop@",
    "/unknown",
    "/",
  ])
  func nonMatchingSlashTextStaysPlain(text: String) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then
    #expect(command == .plain(text))
  }

  @Test func botSuffixRequiresKnownMatchingUsername() {
    // given
    let text = "/new@claw_bot"

    // when
    let command = Command.parse(text, botUsername: nil)

    // then
    #expect(command == .plain(text))
  }
}
