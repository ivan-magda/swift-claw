import ClawCore
import ClawExec
import ClawGateway
import ClawTools
import Foundation

// MARK: - Sandbox Bootstrap

extension DaemonBuilder {
  typealias SandboxStack = SandboxBootstrapResult

  func prepareSandbox() async -> SandboxStack {
    let backend = SandboxBackendFactory.make(config: config, secrets: secrets)
    return await SandboxBootstrapper(
      enabled: config.exec.enabled,
      backend: backend,
      maintenance: backend
    ).prepare()
  }
}

// MARK: - Backend Factory

enum SandboxBackendFactory {
  static func make(config: AppConfig, secrets: Secrets?) -> ContainerBackend? {
    guard config.exec.enabled, let image = config.exec.image else {
      return nil
    }
    let settings = ExecSandboxSettings(
      workloadImage: image,
      memoryMiB: config.exec.memoryMiB,
      cpus: config.exec.cpus
    )
    let redactor = SecretRedactor(secretValues: secrets?.redactionValues ?? [])
    let paths = [
      config.stateRoot.path,
      config.stateRoot.appendingPathComponent("exec-scratch").path,
      FileManager.default.homeDirectoryForCurrentUser.path,
      "/usr/local/bin/container",
    ].sorted { first, second in
      first.count > second.count
    }

    return ContainerBackend(
      settings: settings,
      stateRoot: config.stateRoot,
      commands: SwiftSubprocessContainerCommandRunner(),
      sanitizeReason: { text in
        paths.reduce(redactor.redact(text)) { partial, path in
          partial.replacingOccurrences(of: path, with: "[HOST_PATH]")
        }
      }
    )
  }
}
