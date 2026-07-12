import ClawCore

enum ContainerInvocation {
  static func run(
    identity: ExecutionIdentity,
    scratchPath: String,
    cidFilePath: String,
    language: ExecLanguage,
    network: Bool,
    settings: ExecSandboxSettings,
    initImage: String
  ) -> [String] {
    secureRunPrefix(
      identity: identity,
      scratchPath: scratchPath,
      cidFilePath: cidFilePath,
      settings: settings,
      initImage: initImage
    )
      + networkArguments(network)
      + [
        "--entrypoint", interpreter(for: language), settings.workloadImage.description,
        ExecEntrypoint.guestPath(for: language),
      ]
  }

  static func detachedCanary(
    identity: ExecutionIdentity,
    scratchPath: String,
    settings: ExecSandboxSettings,
    initImage: String
  ) -> [String] {
    secureRunPrefix(
      identity: identity,
      scratchPath: scratchPath,
      cidFilePath: nil,
      settings: settings,
      initImage: initImage
    )
      + [
        "--detach", "--network", "none", "--no-dns", "--entrypoint",
        ExecSandboxSettings.pythonInterpreter, settings.workloadImage.description, "-c",
        "import signal; signal.pause()",
      ]
  }

  static func systemStatus() -> [String] { ["system", "status", "--format", "json"] }
  static func systemVersion() -> [String] { ["system", "version", "--format", "json"] }
  static func systemPropertyList() -> [String] {
    ["system", "property", "list", "--format", "json"]
  }
  static func listAll() -> [String] { ["list", "--all", "--format", "json"] }
  static func inspect(_ identity: String) -> [String] { ["inspect", identity] }
  static func inspectImage(_ image: String) -> [String] { ["image", "inspect", image] }
  static func execCanary(_ identity: String, script: String) -> [String] {
    ["exec", "--user", "0", identity, "/bin/sh", "-c", script]
  }
  static func pull(_ image: String) -> [String] {
    ["image", "pull", "--scheme", "https", "--progress", "none", image]
  }
  static func stop(_ identity: String) -> [String] { ["stop", "--time", "1", identity] }
  static func kill(_ identity: String) -> [String] { ["kill", "--signal", "KILL", identity] }
  static func remove(_ identity: String) -> [String] { ["rm", "--force", identity] }
}

// MARK: - Secure Run Grammar

private extension ContainerInvocation {
  static func secureRunPrefix(
    identity: ExecutionIdentity,
    scratchPath: String,
    cidFilePath: String?,
    settings: ExecSandboxSettings,
    initImage: String
  ) -> [String] {
    var arguments = [
      "run", "--scheme", "https", "--progress", "none", "--platform",
      ExecSandboxSettings.platform, "--rm", "--name", identity.name, "--label",
      ExecutionIdentity.ownershipLabelArgument,
    ]
    if let cidFilePath {
      arguments += ["--cidfile", cidFilePath]
    }
    arguments += [
      "--cap-drop", "ALL", "--init", "--init-image", initImage, "--read-only", "--tmpfs",
      "/tmp", "--cpus", String(settings.cpus), "--memory", "\(settings.memoryMiB)M", "--mount",
      "type=bind,source=\(scratchPath),target=\(ExecEntrypoint.guestWorkDirectory),readonly",
    ]
    return arguments
  }

  static func networkArguments(_ enabled: Bool) -> [String] {
    enabled ? ["--network", "default"] : ["--network", "none", "--no-dns"]
  }

  static func interpreter(for language: ExecLanguage) -> String {
    switch language {
    case .python: ExecSandboxSettings.pythonInterpreter
    case .sh: ExecSandboxSettings.shellInterpreter
    }
  }
}
