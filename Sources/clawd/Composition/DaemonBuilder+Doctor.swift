import ClawCore
import ClawData
import ClawGateway
import ClawMCP
import ClawSecrets
import Foundation

// MARK: - Doctor Reporter Assembly

extension DaemonBuilder {
  func makeDoctorReporter(
    sandbox: SandboxStack,
    cooldown: any PrimaryRouteCooldownTracking,
    mcpOutcomes: [MCPServerOutcome]
  ) -> DaemonDoctorReporter {
    DaemonDoctorReporter(
      stores: stores,
      config: config,
      sandbox: sandbox,
      cooldown: cooldown,
      staticAPIKey: secrets.llmApiKey,
      makeManagedStore: makeManagedStore,
      mcp: mcp,
      mcpOutcomes: mcpOutcomes
    )
  }
}

// MARK: - Doctor Report Provider

struct DaemonDoctorReporter: DoctorReporting {
  let stores: ClawStores
  let config: AppConfig
  let sandbox: SandboxBootstrapResult
  let cooldown: any PrimaryRouteCooldownTracking
  let staticAPIKey: String?
  let makeManagedStore: @Sendable () -> any LLMCredentialStore
  let mcp: MCPBootInputs
  let mcpOutcomes: [MCPServerOutcome]

  func scanSkills() async -> SkillScanResult {
    DoctorHealth.skillScan(config: config)
  }

  func report() async -> DoctorReport {
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "config.max_tokens", value: "\(config.llm.maxOutputTokens)", group: .config)
    report.add(key: "db.writable", value: "true", group: .database)

    let now = Date()
    let auth = LLMAuthDoctor.inspect(
      route: config.llm.route,
      staticAPIKey: staticAPIKey,
      now: now,
      makeManagedStore: makeManagedStore
    )
    report.add(key: "llm.auth", value: auth.value, ok: auth.ok, group: .llmRuns)

    report.add(
      contentsOf: HealthRowsBuilder.checks(
        DoctorHealth.inputs(
          stores: stores,
          config: config,
          now: now,
          routeHealth: await LLMRouteHealth.live(
            primaryReference: config.llm.route.configuredReference,
            fallbackReference: config.llm.fallbackRoute?.configuredReference,
            cooldown: cooldown
          )
        )
      )
    )
    report.add(contentsOf: DoctorHealth.schedulerChecks(stores: stores, config: config, now: now))
    report.add(contentsOf: DoctorHealth.approvalChecks(stores: stores, config: config, now: now))
    report.add(
      contentsOf: DoctorHealth.bootSandboxChecks(
        execEnabled: config.exec.enabled,
        health: sandbox.health,
        unavailableReason: sandbox.unavailableReason
      )
    )

    report.add(contentsOf: DoctorHealth.bashChecks(config: config))

    report.add(contentsOf: MCPDoctorRows.rows(config: mcp.config, credentials: mcp.credentials))
    report.add(contentsOf: MCPDoctorRows.bootRows(outcomes: mcpOutcomes))

    if let maintenance = sandbox.maintenance {
      report.add(contentsOf: [SandboxHealthRows.admittingRow(await maintenance.isAdmitting())])
    }

    return report
  }
}
