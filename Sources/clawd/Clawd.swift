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

/// State-root-relative filenames the daemon owns.
enum StateFile {
  static let database = "claw.sqlite"
  static let lock = "clawd.lock"
}
