import ClawCore
import ClawExec
import ClawGateway
import ClawProcess
import ClawTools
import Foundation

// MARK: - Sandbox Bootstrap

extension DaemonBuilder {
  typealias SandboxStack = SandboxBootstrapResult

  func prepareSandbox() async -> SandboxStack {
    let backend = SandboxBackendFactory.make(config: config, redactionValues: redactionValues)
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
  /// `redactionValues` is empty for the offline `doctor` path, which has no daemon's redaction set
  /// to inherit and reports no secret-bearing text.
  static func make(config: AppConfig, redactionValues: [String]) -> ContainerBackend? {
    guard config.exec.enabled, let image = config.exec.image else {
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
      commands: SwiftSubprocessLocalCommandRunner(executablePath: ContainerBackend.cliPath),
      sanitizeReason: { text in
        redactor.redact(text)
      }
    )
  }
}
