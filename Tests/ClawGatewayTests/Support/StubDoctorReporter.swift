@testable import ClawGateway

struct StubDoctorReporter: DoctorReporting {
  var stubbed = DoctorReport()

  func report() async -> DoctorReport {
    stubbed
  }
}
