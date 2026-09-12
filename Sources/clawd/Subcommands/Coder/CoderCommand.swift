import ArgumentParser
import ClawCore
import ClawGateway
import Foundation

struct CoderCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "coder",
    abstract: "Configure native coding tasks.",
    subcommands: [Setup.self]
  )

  struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "setup",
      abstract: "Enable Coder using the tools available in this terminal.",
      discussion: """
        Saves this terminal's absolute PATH entries as CLAW_CODER_PATH in the existing env file. \
        Checks Codex locally without inference, installing tools or importing credentials. \
        Restart the service afterwards and inspect Telegram /status to confirm its environment.
        """
    )

    @Option(help: "Config file (default: $CLAW_ENV_FILE or ~/.swift-claw/clawd.env).")
    var envFile: String?

    @Flag(help: "Show the proposed Coder settings and checks without changing the file.")
    var dryRun = false

    func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      let filePath =
        envFile ?? environment["CLAW_ENV_FILE"]
        ?? NSHomeDirectory() + "/.swift-claw/clawd.env"
      let file = try CoderSetupFile(path: filePath)
      let path = try Self.capturePath(environment["PATH"])

      var selected = environment.merging(file.values) { _, configured in
        configured
      }
      selected[AppConfig.EnvKey.coderPath] = path
      selected[AppConfig.EnvKey.coderEnabled] = "true"

      let config = try CoderConfig.load(environment: selected)
      do {
        let setup = try await CoderBackendSetup.inspect(config, environment: selected)
        Self.emit(
          DoctorReport(checks: CoderHealthRows.rows(config: config, setup: setup)).renderText()
        )

        guard setup.permitsSubmission else {
          throw ValidationError(
            "Codex login is unavailable. Authenticate it as the service account, then rerun setup."
          )
        }
      } catch let error as CoderError {
        if case .unavailable(let message) = error {
          throw ValidationError(message)
        }
        throw ValidationError("Coder checks failed; configuration was not changed.")
      }

      let updates = [
        AppConfig.EnvKey.coderEnabled: "true",
        AppConfig.EnvKey.coderPath: path,
      ]
      Self.emit(
        """
        \nSettings for \(file.url.path):
        \(AppConfig.EnvKey.coderEnabled)=true
        \(AppConfig.EnvKey.coderPath): full captured PATH
        """
      )

      if dryRun {
        Self.emit("Dry run: configuration was not changed.")
      } else {
        let durable = try file.save(updates)
        Self.emit(
          durable
            ? "Saved Coder settings (0600)."
            : "Coder settings were written, but directory durability could not be confirmed."
        )
      }

      Self.emit(
        """

        These checks used this command's environment; they do not prove service authorization.
        Restart your clawd service, then send /status in your private bot chat. Check coder.path,
        the resolved Codex executable and authentication there. GitHub tasks also need gh and its
        login under the service account. After moving or upgrading tools, rerun clawd coder setup.
        """
      )
    }
  }
}

// MARK: - Terminal Environment

private extension CoderCommand.Setup {
  static func capturePath(_ path: String?) throws -> String {
    var seen: Set<String> = []

    let entries = (path ?? "").split(separator: ":").map(String.init).filter { entry in
      entry.hasPrefix("/") && seen.insert(entry).inserted
    }

    guard !entries.isEmpty else {
      throw ValidationError(
        "Run setup from a terminal with Codex and its tools on an absolute PATH."
      )
    }

    return entries.joined(separator: ":")
  }

  static func emit(_ text: String) {
    // swiftlint:disable:next no_print_in_production
    print(text)
  }
}
