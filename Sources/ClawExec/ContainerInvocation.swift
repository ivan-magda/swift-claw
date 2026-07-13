import ClawCore

struct ContainerLaunchContext {
  let identity: ExecutionIdentity
  let scratchPath: String
  let settings: ExecSandboxSettings
  let initImage: String
}

enum ContainerInvocation {
  static func run(
    context: ContainerLaunchContext,
    cidFilePath: String,
    language: ExecLanguage,
    network: Bool
  ) -> [String] {
    secureRunPrefix(context: context, cidFilePath: cidFilePath)
      + networkArguments(network)
      + [
        "--entrypoint",
        interpreter(for: language),
        context.settings.workloadImage.description,
        ExecEntrypoint.guestPath(for: language),
      ]
  }

  static func detachedCanary(context: ContainerLaunchContext) -> [String] {
    secureRunPrefix(context: context, cidFilePath: nil)
      + [
        "--detach",
        "--network",
        "none",
        "--no-dns",
        "--entrypoint",
        ExecSandboxSettings.pythonInterpreter,
        context.settings.workloadImage.description,
        "-c",
        "import signal; signal.pause()",
      ]
  }

  static func systemStatus() -> [String] {
    ["system", "status", "--format", "json"]
  }

  static func systemVersion() -> [String] {
    ["system", "version", "--format", "json"]
  }

  static func systemPropertyList() -> [String] {
    ["system", "property", "list", "--format", "json"]
  }

  static func listAll() -> [String] {
    ["list", "--all", "--format", "json"]
  }

  static func inspect(_ identity: String) -> [String] {
    ["inspect", identity]
  }

  static func inspectImage(_ image: String) -> [String] {
    ["image", "inspect", image]
  }

  static func execCanary(_ identity: String, script: String) -> [String] {
    ["exec", "--user", "0", identity, ExecSandboxSettings.shellInterpreter, "-c", script]
  }

  static func pull(_ image: String) -> [String] {
    ["image", "pull", "--scheme", "https", "--progress", "none", image]
  }

  static func stop(_ identity: String) -> [String] {
    ["stop", "--time", "1", identity]
  }

  static func kill(_ identity: String) -> [String] {
    ["kill", "--signal", "KILL", identity]
  }

  static func remove(_ identity: String) -> [String] {
    ["rm", "--force", identity]
  }

  /// The stop → kill → remove escalation every teardown path walks; callers keep their own
  /// timeout policy per rung.
  static func teardownLadder(_ identity: String) -> [[String]] {
    [stop(identity), kill(identity), remove(identity)]
  }
}

// MARK: - Secure Run Grammar

private extension ContainerInvocation {
  static func secureRunPrefix(
    context: ContainerLaunchContext,
    cidFilePath: String?
  ) -> [String] {
    var arguments = [
      "run", "--scheme", "https", "--progress", "none", "--platform",
      ExecSandboxSettings.platform, "--rm", "--name", context.identity.name, "--label",
      ExecutionIdentity.ownershipLabelArgument,
    ]

    if let cidFilePath {
      arguments += ["--cidfile", cidFilePath]
    }

    arguments += [
      "--cap-drop", "ALL", "--init", "--init-image", context.initImage, "--read-only", "--tmpfs",
      "/tmp", "--cpus", String(context.settings.cpus), "--memory",
      "\(context.settings.memoryMiB)M", "--mount",
      "type=bind,source=\(context.scratchPath),target=\(ExecEntrypoint.guestWorkDirectory),readonly",
    ]

    return arguments
  }

  static func networkArguments(_ enabled: Bool) -> [String] {
    enabled ? ["--network", "default"] : ["--network", "none", "--no-dns"]
  }

  static func interpreter(for language: ExecLanguage) -> String {
    switch language {
    case .python:
      ExecSandboxSettings.pythonInterpreter
    case .sh:
      ExecSandboxSettings.shellInterpreter
    }
  }
}
