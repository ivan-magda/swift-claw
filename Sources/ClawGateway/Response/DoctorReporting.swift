import ClawCore

public protocol DoctorReporting: Sendable {
  func report() async -> DoctorReport
  func scanSkills() async -> SkillScanResult
}
