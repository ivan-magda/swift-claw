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

  @Test(arguments: [
    ("/schedule", Command.schedule(.list)),
    ("/schedule list", .schedule(.list)),
    ("/schedule LIST", .schedule(.list)),
    ("/SCHEDULE@CLAW_BOT list", .schedule(.list)),
    (
      "/schedule every weekday at 07:00 — summarize my unread items",
      .schedule(.create(text: "every weekday at 07:00 — summarize my unread items"))
    ),
  ])
  func scheduleCommandParses(text: String, expected: Command) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then
    #expect(command == expected)
  }

  @Test(arguments: [
    ("/pause 3", Command.pause(jobId: 3)),
    ("/pause", .pause(jobId: nil)),
    ("/pause abc", .pause(jobId: nil)),
    ("/pause -2", .pause(jobId: nil)),
    ("/resume 3", .resume(jobId: 3)),
    ("/resume", .resume(jobId: nil)),
    ("/runnow 12", .runNow(jobId: 12)),
    ("/RUNNOW@CLAW_BOT 12", .runNow(jobId: 12)),
    ("/cancel 3", .cancelJob(jobId: 3)),
    ("/cancel", .cancelJob(jobId: nil)),
    ("/cancel three", .cancelJob(jobId: nil)),
  ])
  func verbCommandsParse(text: String, expected: Command) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then
    #expect(command == expected)
  }

  @Test func plainCancelWordStaysPlainText() {
    // given / when / then — slash-first parsing: only "/cancel" is the verb; the bare word
    // keeps its confirmation-rejection meaning (spec §9)
    #expect(Command.parse("cancel", botUsername: "claw_bot") == .plain("cancel"))
    #expect(
      Command.parse("Cancel that idea", botUsername: "claw_bot")
        == .plain("Cancel that idea")
    )
  }

  @Test func helpParses() {
    // given / when / then
    #expect(Command.parse("/help", botUsername: "claw_bot") == .help)
    #expect(Command.parse("/HELP@CLAW_BOT", botUsername: "claw_bot") == .help)
    #expect(Command.parse("please /help me", botUsername: "claw_bot") == .plain("please /help me"))
  }

  @Test func doctorParses() {
    // given / when / then
    #expect(Command.parse("/doctor", botUsername: "claw_bot") == .doctor)
    #expect(Command.parse("/DOCTOR@CLAW_BOT", botUsername: "claw_bot") == .doctor)
    #expect(Command.parse("run /doctor", botUsername: "claw_bot") == .plain("run /doctor"))
  }

  @Test func statusParsesAsDoctorAlias() {
    // given / when / then
    #expect(Command.parse("/status", botUsername: "claw_bot") == .doctor)
    #expect(Command.parse("/STATUS@CLAW_BOT", botUsername: "claw_bot") == .doctor)
    #expect(Command.parse("see /status", botUsername: "claw_bot") == .plain("see /status"))
  }

  @Test func mcpParses() {
    // given / when / then
    #expect(Command.parse("/mcp", botUsername: "claw_bot") == .mcp)
    #expect(Command.parse("/MCP@CLAW_BOT", botUsername: "claw_bot") == .mcp)
    #expect(Command.parse("check /mcp", botUsername: "claw_bot") == .plain("check /mcp"))
  }

  @Test func mcpTakesNoArgumentsSoNoArgumentCanBecomeAManagementVerb() {
    // given — an argument tail that reads like a management command.
    // when / then — it parses to the same argument-free status request.
    #expect(Command.parse("/mcp add https://evil.test/mcp", botUsername: "claw_bot") == .mcp)
    #expect(Command.parse("/mcp set-token linear hunter2", botUsername: "claw_bot") == .mcp)
  }

  @Test(arguments: [
    "/skills",
    "/SKILLS",
    "/skills@claw_bot",
    "/SKILLS@CLAW_BOT include rejected",
  ])
  func skillsParsesAsReadOnlyDiagnostics(text: String) {
    // given
    let botUsername = "claw_bot"

    // when
    let command = Command.parse(text, botUsername: botUsername)

    // then
    #expect(command == .skills)
  }

  @Test(arguments: [
    (Command.remember(.invalid), true),
    (.memory(.review), true),
    (.schedule(.list), true),
    (.pause(jobId: 1), true),
    (.resume(jobId: 1), true),
    (.runNow(jobId: 1), true),
    (.cancelJob(jobId: 1), true),
    (.start, false),
    (.stop, false),
    (.new, false),
    (.help, false),
    (.doctor, false),
    (.mcp, false),
    (.skills, false),
    (.plain("hello"), false),
  ])
  func ownerScopedCommandsAreDirectOnly(command: Command, expected: Bool) {
    // given — the command and expected scope come from the parameter table

    // when
    let isDirectOnly = command.isDirectOnly

    // then
    #expect(isDirectOnly == expected)
  }
}
