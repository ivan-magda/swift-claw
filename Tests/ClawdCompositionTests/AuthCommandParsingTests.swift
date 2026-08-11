import ArgumentParser
import ClawAuth
import Testing

@testable import clawd

@Suite struct AuthCommandParsingTests {
  @Test func authSubcommandsParseWithoutAProviderOption() throws {
    // given
    let loginArguments = ["auth", "login"]
    let statusArguments = ["auth", "status"]
    let logoutArguments = ["auth", "logout"]

    // when
    let login = try Clawd.parseAsRoot(loginArguments)
    let status = try Clawd.parseAsRoot(statusArguments)
    let logout = try Clawd.parseAsRoot(logoutArguments)

    // then
    #expect(login is AuthCommand.Login)
    #expect(status is AuthCommand.Status)
    #expect(logout is AuthCommand.Logout)
  }

  @Test func authHelpDoesNotAdvertiseAProviderOption() {
    // given
    let removedOption = "--provider"

    // when
    let helpMessages = [
      Clawd.helpMessage(for: AuthCommand.Login.self),
      Clawd.helpMessage(for: AuthCommand.Status.self),
      Clawd.helpMessage(for: AuthCommand.Logout.self),
    ]

    // then
    #expect(
      helpMessages.allSatisfy { message in
        message.contains(removedOption) == false
      }
    )
  }

  @Test func providerOptionIsRejectedAsUnknown() {
    // given
    let removedOption = "--provider"
    let arguments = [
      "auth", "status", removedOption, ChatGPTProviderMetadata.providerID.rawValue,
    ]

    // when
    do {
      _ = try Clawd.parseAsRoot(arguments)
      Issue.record("expected the removed provider option to be rejected")
    } catch {
      // then
      let message = Clawd.message(for: error)
      #expect(message.lowercased().contains("unknown option"))
      #expect(message.contains(removedOption))
    }
  }
}
