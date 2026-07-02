import Testing

@testable import ClawCore

@Suite struct RememberCommandTests {
  @Test(arguments: [
    ("project: ship 3a", RememberCommand.save(kind: .project, text: "ship 3a")),
    ("buy milk", .save(kind: .user, text: "buy milk")),
    ("PROJECT: ship 3a", .save(kind: .project, text: "ship 3a")),
    (
      "reference: https://example.com/runbook",
      .save(kind: .reference, text: "https://example.com/runbook")
    ),
    ("note: buy milk", .save(kind: .user, text: "note: buy milk")),
    (
      "  feedback: prefers concise status  ", .save(kind: .feedback, text: "prefers concise status")
    ),
  ])
  func parsesExpectedForms(arguments: String, expected: RememberCommand) {
    // given
    let input = Substring(arguments)

    // when
    let command = RememberCommand.parse(arguments: input)

    // then
    #expect(command == expected)
  }

  @Test(arguments: [
    "",
    "   ",
    "project:",
    "project:   ",
  ])
  func rejectsInvalidForms(arguments: String) {
    // given
    let input = Substring(arguments)

    // when
    let command = RememberCommand.parse(arguments: input)

    // then
    #expect(command == .invalid)
  }
}
