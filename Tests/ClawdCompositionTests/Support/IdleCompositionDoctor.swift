import ClawCore
import ClawGateway

/// An inert doctor for composition tests that build the router without exercising `/status` or
/// `/skills`: an empty report and no installed skills.
struct IdleCompositionDoctor: DoctorReporting {
  func report() async -> DoctorReport {
    DoctorReport()
  }

  func scanSkills() async -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}
