import Testing

@testable import clawd

@Suite struct BotMenuCommandsTests {
  @Test func registeredCatalogIncludesOwnerSkillDiagnostics() throws {
    // given
    let catalog = DaemonBuilder.botMenuCommands

    // when
    let skills = try #require(
      catalog.first { command in
        command.command == "skills"
      }
    )

    // then
    #expect(skills.description.contains("accepted"))
    #expect(skills.description.contains("rejected"))
  }

  @Test func registeredCatalogIncludesTheLearningView() throws {
    // given
    let catalog = DaemonBuilder.botMenuCommands

    // when
    let learning = try #require(
      catalog.first { command in
        command.command == "learning"
      }
    )

    // then — omitting registration hides a routed owner command from Telegram's picker.
    #expect(learning.description.contains("learning"))
  }
}
