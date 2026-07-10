import ArgumentParser
import Foundation

@main
struct Clawd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clawd",
    abstract: "swift-claw — single-owner Telegram assistant daemon.",
    version: ClawdVersion.current,
    subcommands: [
      RunCommand.self,
      DoctorCommand.self,
      SecretsCommand.self,
    ],
    defaultSubcommand: RunCommand.self
  )
}
