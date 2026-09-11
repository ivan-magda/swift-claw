import ClawCore
import ClawGateway

actor IdleCompositionTurns: TurnDispatching {
  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws {}
}

struct IdleCompositionScheduleParser: ScheduleDraftParsing {
  func parse(ownerText: String, sessionId: Int64) async -> ScheduleDraftParseResult {
    .unparseable
  }
}

struct IdleCompositionDoctor: DoctorReporting {
  func report() async -> DoctorReport {
    DoctorReport()
  }

  func scanSkills() async -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}
