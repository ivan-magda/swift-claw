import Foundation

public protocol ConferenceServing: Sendable {
  func currentCase() async throws -> ConferenceCase
  func prepareSubmission(answer: String) async throws -> PreparedConferenceSubmission
  func submit(
    _ prepared: PreparedConferenceSubmission,
    context: ToolExecutionContext
  ) async throws -> ConferenceSubmission
  func status(
    submissionID: UUID?,
    context: ToolExecutionContext
  ) async throws -> ConferenceSubmission?
}
