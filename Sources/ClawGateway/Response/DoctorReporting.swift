public protocol DoctorReporting: Sendable {
  func report() async -> DoctorReport
}
