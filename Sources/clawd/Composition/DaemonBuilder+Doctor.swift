import ClawCore
import ClawData
import ClawGateway
import Foundation

// MARK: - Doctor Report Provider

struct DaemonDoctorReporter: DoctorReporting {
  let stores: ClawStores
  let config: AppConfig
  let sandbox: SandboxBootstrapResult

  func report() async -> DoctorReport {
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "config.max_tokens", value: "\(config.llm.maxOutputTokens)", group: .config)
    report.add(key: "db.writable", value: "true", group: .database)

    let now = Date()
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
