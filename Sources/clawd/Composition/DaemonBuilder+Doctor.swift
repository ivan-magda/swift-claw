import ClawCore
import ClawData
import ClawGateway
import ClawSecrets
import Foundation

// MARK: - Doctor Report Provider

struct DaemonDoctorReporter: DoctorReporting {
  let stores: ClawStores
  let config: AppConfig
  let sandbox: SandboxBootstrapResult
  /// The static bearer already resolved at boot, so the credential row reports the current route's
  /// key presence without re-reading secrets.
  let staticAPIKey: String?

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
      makeManagedStore: {
        EncryptedLLMCredentialStore(stateRoot: config.stateRoot)
      }
    )
    report.add(key: "llm.auth", value: auth.value, ok: auth.ok, group: .llmRuns)

    report.add(
      contentsOf: HealthRowsBuilder.checks(
        DoctorHealth.inputs(stores: stores, config: config, now: now)
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

    if let maintenance = sandbox.maintenance {
      report.add(contentsOf: [SandboxHealthRows.admittingRow(await maintenance.isAdmitting())])
    }

    return report
  }
}
