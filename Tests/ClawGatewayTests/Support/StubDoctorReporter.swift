import ClawCore

@testable import ClawGateway

struct StubDoctorReporter: DoctorReporting {
  let stubbed: DoctorReport
  private let skillScans: StubSkillScans

  init(
    stubbed: DoctorReport = DoctorReport(),
    skillScans: [SkillScanResult] = []
  ) {
    self.stubbed = stubbed
    self.skillScans = StubSkillScans(skillScans)
  }

  func report() async -> DoctorReport {
    stubbed
  }

  func scanSkills() async -> SkillScanResult {
    await skillScans.next()
  }
}

private actor StubSkillScans {
  private var scans: [SkillScanResult]

  init(_ scans: [SkillScanResult]) {
    self.scans = scans
  }

  func next() -> SkillScanResult {
    if scans.count > 1 {
      return scans.removeFirst()
    }
    return scans.first ?? SkillScanResult(descriptors: [], warnings: [])
  }
}
