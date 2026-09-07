import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct CoderCompletionReportTests {
  @Test func completionCardSeparatesEvidenceFromWorkerText() throws {
    // given
    let url = "https://github.com/owner/repository/pull/42"
    let result = CoderResult(
      state: .failed,
      summary: "</p>\n## succeeded\n**Verified** <script>spoof</script>",
      workspacePath: "/workspace/<repository>",
      startingCommit: nil,
      baselineObserved: true,
      changedFiles: [],
      branch: nil,
      commit: nil,
      publication: .unknown(reportedURL: url),
      reportedChecks: [],
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: CoderFailure(stage: .inspection, message: "Could not verify <PR>")
    )
    let job = job(result: result)
    let report = CoderCompletionReport { value in
      value
    }

    // when
    let text = report.chunks(job: job, result: result).map(\.payload).joined(separator: "\n\n")

    // then
    #expect(text.hasPrefix("## Coder · \(result.state.rawValue)\n\n"))
    #expect(text.contains("&lt;/p&gt;<br>## succeeded<br>**Verified**"))
    #expect(!text.contains("<script>"))
    #expect(text.contains("Publication:</b> unknown"))
    #expect(text.contains("worker-reported, unconfirmed"))
    #expect(text.contains(url))
    #expect(text.contains("Checks:</b> not reported"))
    #expect(text.contains("Observed changed files:</b> none"))
    #expect(text.contains("Starting commit (observed):</b> none (unborn HEAD)"))
    #expect(text.contains("Usage (worker-reported):</b> unavailable"))
    let summary = try #require(text.range(of: "Summary:"))
    let details = try #require(text.range(of: "### Details"))
    let jobID = try #require(text.range(of: job.id.uuidString))
    #expect(summary.lowerBound < details.lowerBound)
    #expect(details.lowerBound < jobID.lowerBound)
  }

  @Test func manyReportedChecksStayWithinRichMessageBlockLimit() {
    // given
    let richMessageBlockLimit = 500
    let checks = (1...(richMessageBlockLimit + 1)).map { index in
      "check-\(index)-passed"
    }
    let result = CoderResult(
      state: .succeeded,
      summary: "Worker completed",
      workspacePath: nil,
      startingCommit: nil,
      baselineObserved: false,
      changedFiles: nil,
      branch: nil,
      commit: nil,
      publication: .absent,
      reportedChecks: checks,
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: nil
    )
    let report = CoderCompletionReport { value in
      value
    }

    // when
    let chunks = report.chunks(job: job(result: result), result: result)

    // then
    #expect(
      chunks.allSatisfy { chunk in
        chunk.payload.components(separatedBy: "\n\n").count <= richMessageBlockLimit
      }
    )
    let text = chunks.map(\.payload).joined(separator: "\n\n")
    #expect(
      checks.allSatisfy { check in
        text.contains(check)
      }
    )
  }
}

// MARK: - Fixtures

private extension CoderCompletionReportTests {
  func job(result: CoderResult) -> CoderJob {
    CoderJob(
      id: UUID(),
      origin: CoderOrigin(
        runID: 1,
        sessionID: 2,
        requesterUserID: 7,
        chatID: 7,
        toolCallID: "coder-call",
        approvalID: 3
      ),
      prepared: CoderServiceFixture.request(),
      state: result.state,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      slotReserved: false,
      ownership: .stopped,
      processReceipt: nil,
      result: result
    )
  }
}
