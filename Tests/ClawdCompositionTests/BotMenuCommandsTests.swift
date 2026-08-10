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
}
