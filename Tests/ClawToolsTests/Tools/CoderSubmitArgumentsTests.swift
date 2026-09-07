import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct CoderSubmitArgumentsTests {
  @Test(arguments: [
    CoderSource.local(path: "/repository"),
    .githubRepository(url: "https://github.com/owner/repository"),
    .githubIssue(url: "https://github.com/owner/repository/issues/42"),
  ])
  func wireRequestPreservesSourceAndScope(_ source: CoderSource) throws {
    // given
    let inPlace: Bool
    if case .local = source {
      inPlace = true
    } else {
      inPlace = false
    }
    let workspace: CoderWorkspaceMode = inPlace ? .inPlace : .separate
    let startRef: String? = inPlace ? nil : "retry-base"
    let sourceJSON = try #require(CanonicalJSON.encode(source))
    let startRefJSON = try #require(CanonicalJSON.encode(startRef))
    let arguments = try #require(
      JSONValue.parse(
        """
        {"source":\(sourceJSON),"task":"Fix retries","workspace":"\(workspace.rawValue)",
        "start_ref":\(startRefJSON),"deliverable":"pullRequest","base_branch":"release",
        "instructions":"Run the checks","publish_existing_changes":\(inPlace)}
        """
      )
    )

    // when
    let request = try CoderSubmitArguments.decode(arguments)

    // then
    #expect(
      request
        == CoderRequest(
          source: source,
          task: "Fix retries",
          workspace: workspace,
          startRef: startRef,
          deliverable: .pullRequest,
          baseBranch: "release",
          instructions: "Run the checks",
          publishExistingChanges: inPlace
        )
    )
  }

  @Test func rejectsMultipleIndividuallyValidSources() throws {
    // given
    let arguments = try #require(
      JSONValue.parse(
        """
        {"source":{"local":{"path":"/repository"},
        "githubIssue":{"url":"https://github.com/owner/repository/issues/42"}},
        "task":"Fix retries","workspace":"separate","deliverable":"pullRequest"}
        """
      )
    )

    // when / then
    do {
      _ = try CoderSubmitArguments.decode(arguments)
      Issue.record("Multiple valid source cases were accepted")
    } catch let error as CoderError {
      guard case .invalidRequest = error else {
        Issue.record("Unexpected Coder error: \(error)")
        return
      }
    }
  }
}
