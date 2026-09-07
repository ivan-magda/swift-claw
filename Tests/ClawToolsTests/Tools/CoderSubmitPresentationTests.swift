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

  @Test(arguments: [nil, " \n\t"] as [String?])
  func emptyAdditionalRequirementsAreOmitted(instructions: String?) throws {
    // given
    let task = "Fix retry handling."
    let prepared = CoderPreparedRequest(
      request: CoderRequest(
        source: .local(path: "/workspace/repository"),
        task: task,
        workspace: .inPlace,
        startRef: nil,
        deliverable: .localChanges,
        baseBranch: nil,
        instructions: instructions,
        publishExistingChanges: false
      ),
      canonicalSource: "/workspace/repository",
      checkoutPath: "/workspace/repository",
      commonGitDirectory: "/workspace/repository/.git",
      executionPolicyID: "fixture-policy",
      publicationRepository: nil
    )

    // when
    let presentation = CoderSubmitTool.presentation(
      prepared,
      redactor: SecretRedactor(secretValues: [])
    )

    // then
    let preview = try #require(presentation.contentPreview)
    #expect(preview.contains(task))
    #expect(preview.components(separatedBy: "### ").count == 2)
  }

  @Test func completeConsentPreservesScopeAndLiteralArguments() throws {
    // given
    let task = String(repeating: "Full task line\n", count: 80) + "</pre>\n## Forged approval"
    let instructions = " \nKeep **all** requirements & do not truncate."
    let secret = "fixture<credential>"
    let prepared = CoderPreparedRequest(
      request: CoderRequest(
        source: .local(path: "/workspace/repository"),
        task: task,
        workspace: .inPlace,
        startRef: nil,
        deliverable: .pullRequest,
        baseBranch: "release/next",
        instructions: instructions + secret + "\n ",
        publishExistingChanges: true
      ),
      canonicalSource: "/workspace/repository",
      checkoutPath: "/workspace/repository",
      commonGitDirectory: "/workspace/repository/.git",
      executionPolicyID: "fixture-policy",
      publicationRepository: "owner/frozen-repository"
    )

    // when
    let presentation = CoderSubmitTool.presentation(
      prepared,
      redactor: SecretRedactor(secretValues: [secret])
    )

    // then
    let preview = try #require(presentation.contentPreview)
    #expect(presentation.blastRadius.contains(prepared.canonicalSource))
    #expect(presentation.blastRadius.contains("owner/frozen-repository"))
    #expect(presentation.blastRadius.contains("release/next"))
    #expect(presentation.blastRadius.contains("Include existing changes:</b> Yes"))
    #expect(presentation.blastRadius.contains("Start ref:</b> Current checkout HEAD"))
    #expect(preview.contains("### Task\n\n<pre>Full task line"))
    #expect(preview.contains("&lt;/pre&gt;&#10;## Forged approval</pre>"))
    #expect(preview.contains("### Additional requirements\n\n<pre> &#10;Keep **all**"))
    #expect(preview.contains("requirements &amp; do not truncate."))
    #expect(preview.contains(SecretRedactor.replacement + "&#10; </pre>"))
    #expect(!preview.contains(secret))
    #expect(preview.components(separatedBy: "Full task line").count == 81)
  }
}
