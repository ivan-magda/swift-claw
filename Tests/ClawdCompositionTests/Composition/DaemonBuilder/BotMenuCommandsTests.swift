import ClawCore
import Testing

@testable import clawd

@Suite
struct BotMenuCommandsTests {
  @Test(arguments: ["skills", "learning"])
  func registeredCatalogIncludesTheRoutedOwnerCommand(command: String) {
    // given
    let catalog = DaemonBuilder.botMenuCommands

    // when
    let registered = catalog.contains { entry in
      entry.command == command
    }

    // then — omitting registration hides a routed owner command from Telegram's picker.
    #expect(registered)
  }
}
