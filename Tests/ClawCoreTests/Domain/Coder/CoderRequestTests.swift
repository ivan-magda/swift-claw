import Testing

@testable import ClawCore

@Suite struct CoderRequestTests {
  @Test(arguments: [
    CoderSource.githubRepository(url: "https://github.com/owner/project"),
    .githubIssue(url: "https://github.com/owner/project/issues/12"),
  ]) func rejectsInvalidCombinations(source: CoderSource) {
    // given
    let request = request(source: source)

    // when
    let validate = { try request.validated() }

    // then
    #expect(throws: CoderError.self) {
      try validate()
    }
  }

  @Test func issueCanSupplyTask() throws {
    // given
    let request = request(
      source: .githubIssue(url: "https://github.com/owner/project/issues/12"),
      task: nil,
      workspace: .separate
    )

    // when
    let validated = try request.validated()

    // then
    #expect(validated == request)
  }

  @Test(arguments: [
    CoderSource.local(path: "/tmp/project"),
    .githubRepository(url: "https://github.com/owner/project"),
  ]) func separateSourcesAcceptStartRef(source: CoderSource) throws {
    // given
    let request = request(source: source, workspace: .separate, startRef: "release")

    // when
    let validated = try request.validated()

    // then
    #expect(validated == request)
  }

  @Test(arguments: [
    (CoderSource.githubRepository(url: "https://github.com/owner/project"), nil as String?),
    (.githubRepository(url: "https://github.com/owner/project"), " \n"),
    (.local(path: "/tmp/project"), nil),
  ]) func repositorySourcesRequireTask(source: CoderSource, task: String?) {
    // given
    let request = request(source: source, task: task, workspace: .separate)

    // when
    let validate = { try request.validated() }

    // then
    #expect(throws: CoderError.self) {
      try validate()
    }
  }

  @Test func inPlaceRejectsStartRef() {
    // given
    let request = request(startRef: "release")

    // when
    let validate = { try request.validated() }

    // then
    #expect(throws: CoderError.self) {
      try validate()
    }
  }

  @Test func inPlaceAllowsPRTargetAndPreservesTaskData() throws {
    // given
    let request = request(
      task: "  Fix `retry()`; $(leave as data)\n",
      deliverable: .pullRequest,
      baseBranch: "release",
      instructions: "\nFollow --the local guidance  "
    )

    // when
    let validated = try request.validated()

    // then
    #expect(validated == request)
  }

  @Test func separateRejectsPublishingExistingChanges() {
    // given
    let request = request(workspace: .separate, publishExistingChanges: true)

    // when
    let validate = { try request.validated() }

    // then
    #expect(throws: CoderError.self) {
      try validate()
    }
  }

  @Test func localPathMustBeAbsolute() {
    // given
    let request = request(source: .local(path: "relative/project"))

    // when
    let validate = { try request.validated() }

    // then
    #expect(throws: CoderError.self) {
      try validate()
    }
  }

  @Test(arguments: [
    CoderSource.githubRepository(url: "http://github.com/owner/project"),
    .githubRepository(url: "https://example.com/owner/project"),
    .githubRepository(url: "https://user@github.com/owner/project"),
    .githubRepository(url: "https://github.com/owner/project?token=value"),
    .githubRepository(url: "https://github.com/owner/project#readme"),
    .githubRepository(url: "https://github.com:443/owner/project"),
    .githubRepository(url: "https://github.com/owner/project/pulls"),
    .githubRepository(url: "https://github.com/owner/--upload-pack"),
    .githubRepository(url: "https://github.com/owner/%70roject"),
    .githubIssue(url: "https://github.com/owner/project/pull/12"),
    .githubIssue(url: "https://github.com/owner/project/issues/0"),
    .githubIssue(url: "https://github.com/owner/project/issues/+1"),
  ]) func githubURLValidation(source: CoderSource) {
    // given
    let request = request(source: source, workspace: .separate)

    // when
    let validate = { try request.validated() }

    // then
    #expect(throws: CoderError.self) {
      try validate()
    }
  }
}

// MARK: - Requests

private extension CoderRequestTests {
  func request(
    source: CoderSource = .local(path: "/tmp/project"),
    task: String? = "Fix retry handling",
    workspace: CoderWorkspaceMode = .inPlace,
    startRef: String? = nil,
    deliverable: CoderDeliverable = .localChanges,
    baseBranch: String? = nil,
    instructions: String? = nil,
    publishExistingChanges: Bool = false
  ) -> CoderRequest {
    CoderRequest(
      source: source,
      task: task,
      workspace: workspace,
      startRef: startRef,
      deliverable: deliverable,
      baseBranch: baseBranch,
      instructions: instructions,
      publishExistingChanges: publishExistingChanges
    )
  }
}
