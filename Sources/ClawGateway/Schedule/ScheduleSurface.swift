import ClawCore

/// The scheduling collaborators the router needs, bundled so `MessageRouter.init` grows one
/// parameter instead of five. Composition builds exactly one; tests swap the parser for a fake.
/// The init takes the raw calculator (the actual injectable dependency) and derives the policy —
/// pure logic — itself, so construction sites stay one-liner-simple.
public struct ScheduleSurface: Sendable {
  public let parser: any ScheduleDraftParsing
  public let validator: ScheduleDraftValidator

  public let policy: OccurrencePolicy

  public let jobs: any ScheduledJobStore
  public let commands: any ScheduleCommandStore

  public init(
    parser: any ScheduleDraftParsing,
    validator: ScheduleDraftValidator,
    calculator: OccurrenceCalculator,
    jobs: any ScheduledJobStore,
    commands: any ScheduleCommandStore
  ) {
    self.parser = parser
    self.validator = validator

    self.policy = OccurrencePolicy(calculator: calculator)

    self.jobs = jobs
    self.commands = commands
  }
}
