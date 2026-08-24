import ClawCore
import ClawGateway
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import Testing

@testable import clawd

@Suite("bash tool registration")
struct BashToolRegistrationTests {
  @Test("the tool is absent while host execution is disabled")
  func absentWhileDisabled() throws {
    // given
    let config = try Self.config(environment: [:])

    // when
    let names = try Self.toolNames(config: config)

    // then
    #expect(names.contains(BashTool.toolName) == false)
  }

  @Test("the tool is absent when the configured shell is missing")
  func absentWhenShellIsMissing() throws {
    // given
    let missing = NSTemporaryDirectory() + "clawd-missing-shell-" + UUID().uuidString
    let config = try Self.config(environment: [
      AcceptanceEnv.bashEnabled: "true",
      AcceptanceEnv.bashShell: missing,
    ])

    // when
    let names = try Self.toolNames(config: config)

    // then
    #expect(names.contains(BashTool.toolName) == false)
  }

  @Test("the tool is absent when the configured shell is not executable")
  func absentWhenShellIsNotExecutable() throws {
    // given
    let shellPath = NSTemporaryDirectory() + "clawd-plain-shell-" + UUID().uuidString
    FileManager.default.createFile(
      atPath: shellPath,
      contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: NSNumber(value: 0o644)]
    )
    defer { try? FileManager.default.removeItem(atPath: shellPath) }
    let config = try Self.config(environment: [
      AcceptanceEnv.bashEnabled: "true",
      AcceptanceEnv.bashShell: shellPath,
    ])

    // when
    let names = try Self.toolNames(config: config)

    // then
    #expect(names.contains(BashTool.toolName) == false)
  }

  @Test("the tool is present when enabled with a launchable shell")
  func presentWhenEnabledWithAValidShell() throws {
    // given
    let config = try Self.config(environment: [
      AcceptanceEnv.bashEnabled: "true",
      AcceptanceEnv.bashShell: "/bin/sh",
    ])

    // when
    let names = try Self.toolNames(config: config)

    // then
    #expect(names.contains(BashTool.toolName))
  }

  @Test("registering the tool changes the policy fingerprint")
  func registrationMovesThePolicyVersion() throws {
    // given
    let disabled = try Self.config(environment: [:])
    let enabled = try Self.config(environment: [
      AcceptanceEnv.bashEnabled: "true",
      AcceptanceEnv.bashShell: "/bin/sh",
    ])

    // when
    let without = try Self.staticSubhash(config: disabled)
    let with = try Self.staticSubhash(config: enabled)

    // then
    #expect(without != with)
  }
}

// MARK: - Composition

private extension BashToolRegistrationTests {
  struct Composed {
    let builder: DaemonBuilder
    let workspace: FileSystemWorkspace
    let dispatcher: GatedToolDispatcher
  }

  static func config(environment: [String: String]) throws -> AppConfig {
    var environment = environment
    environment[AppConfig.EnvKey.stateRoot] =
      NSTemporaryDirectory() + "clawd-bash-" + UUID().uuidString
    environment[AppConfig.EnvKey.llmModel] = "gpt-4o"
    environment[AcceptanceEnv.baseURL] = "https://primary.example/v1"
    return try AppConfig.load(environment: environment)
  }

  /// The production catalog builder over an empty sandbox, so the only thing that can move the
  /// tool list is the bash config under test.
  static func compose(config: AppConfig) throws -> Composed {
    let builder = try CompositionAcceptance.makeBuilder(
      http: ScriptedHTTPExecutor([]),
      config: config
    )
    let workspace = FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config))
    let dispatcher = builder.makeToolDispatcher(
      workspace: workspace,
      sandbox: SandboxBootstrapResult(
        backend: nil,
        maintenance: nil,
        health: nil,
        unavailableReason: nil
      ),
      mcpTools: [],
      echo: RecordingInvocationEcho()
    )
    return Composed(builder: builder, workspace: workspace, dispatcher: dispatcher)
  }

  static func toolNames(config: AppConfig) throws -> [String] {
    try compose(config: config).dispatcher.definitions.map(\.name)
  }

  static func staticSubhash(config: AppConfig) throws -> String {
    let composed = try compose(config: config)
    return composed.builder.policyStaticSubhash(
      toolDispatcher: composed.dispatcher,
      workspace: composed.workspace
    )
  }
}
