import ClawCore
import Testing

@testable import ClawTools

@Suite struct CoderSubmitPresentationTests {
  @Test func issueOnlyApprovalDisplaysSelectedIssue() throws {
    // given
    let issue = "https://github.com/owner/repository/issues/42"
    let request = try CoderRequest(
      source: .githubIssue(url: issue),
      task: nil,
      workspace: .separate,
      startRef: nil,
      deliverable: .pullRequest,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    ).validated()
    let prepared = CoderPreparedRequest(
      request: request,
      canonicalSource: "https://github.com/owner/repository",
      checkoutPath: nil,
      commonGitDirectory: nil,
      executionPolicyID: "fixture-policy",
      publicationRepository: "https://github.com/owner/repository"
    )

    // when
    let presentation = CoderSubmitTool.presentation(
      prepared,
      redactor: SecretRedactor(secretValues: [])
    )

    // then
    #expect(presentation.blastRadius.contains(issue))
    #expect(presentation.blastRadius.contains("GitHub issue"))
  }
}
