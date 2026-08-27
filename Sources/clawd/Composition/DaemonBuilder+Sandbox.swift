import ClawCore
import ClawExec
import ClawGateway
import ClawSubprocess
import ClawTools
import Foundation

// MARK: - Sandbox Bootstrap

extension DaemonBuilder {
  typealias SandboxStack = SandboxBootstrapResult

  func prepareSandbox() async -> SandboxStack {
    let backend = SandboxBackendFactory.make(
      config: config,
      redactionValues: redactionValues
    )

    return await SandboxBootstrapper(
      enabled: config.exec.enabled,
      backend: backend,
      maintenance: backend
    )
    .prepare()
  }
}

// MARK: - Backend Factory

enum SandboxBackendFactory {
  private static let containerExecutablePath = "/usr/local/bin/container"

  static func make(
    config: AppConfig,
    redactionValues: [String]
  ) -> ContainerBackend? {
    guard
      config.exec.enabled,
      let image = config.exec.image
    else {
      return nil
    }

    let settings = ExecSandboxSettings(
      workloadImage: image,
      memoryMiB: config.exec.memoryMiB,
      cpus: config.exec.cpus
    )
    let redactor = SecretRedactor(secretValues: redactionValues)

    return ContainerBackend(
      settings: settings,
      stateRoot: config.stateRoot,
      commands: SwiftSubprocessRunner(executablePath: Self.containerExecutablePath),
      sanitizeReason: { text in
        redactor.redact(text)
      }
    )
  }
}
