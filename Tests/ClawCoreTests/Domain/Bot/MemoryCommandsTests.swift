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

@Suite struct MemoryCommandParseTests {
  @Test(arguments: [
    ("", MemoryCommand.review),
    ("   ", .review),
    ("review", .review),
    ("  review  ", .review),
    ("project", .filter(kind: .project)),
    ("PROJECT", .filter(kind: .project)),
    ("show 3", .show(id: 3)),
    ("  SHOW   42  ", .show(id: 42)),
    ("delete 7", .delete(id: 7)),
    (" DELETE 9 ", .delete(id: 9)),
  ])
  func parsesExpectedForms(arguments: String, expected: MemoryCommand) {
    // given
    let input = Substring(arguments)

    // when
    let command = MemoryCommand.parse(arguments: input)

    // then
    #expect(command == expected)
  }

  @Test(arguments: [
    "unknown",
    "show",
    "show abc",
    "show 0",
    "show -1",
    "show 1 extra",
    "delete",
    "delete abc",
    "delete 0",
    "delete -1",
    "delete 1 extra",
    "project extra",
    "review now",
  ])
  func rejectsInvalidForms(arguments: String) {
    // given
    let input = Substring(arguments)

    // when
    let command = MemoryCommand.parse(arguments: input)

    // then
    #expect(command == .invalid)
  }
}
