import ClawCore

struct CoderCompletionReport: Sendable {
  private let redact: @Sendable (String) -> String

  init(redact: @escaping @Sendable (String) -> String) {
    self.redact = redact
  }

  func chunks(job: CoderJob, result: CoderResult) -> [OutboxChunk] {
    var blocks = ["## Coder · \(redact(result.state.rawValue))", field("Summary", result.summary)]

    if job.ownership != .none && job.ownership != .stopped {
      blocks.append(
        "⚠ Process ownership unresolved; reservation retained. Operator recovery required."
      )
    }

    if let failure = result.failure {
      blocks.append(field("Failure (\(failure.stage.rawValue))", failure.message))
    }

    blocks += publicationEvidence(result.publication)
    blocks += checkEvidence(result.reportedChecks)
    blocks += workspaceEvidence(result)
    blocks += ["### Details", field("Job ID", job.id.uuidString)]
    blocks += executionEvidence(result)

    return CoderCardMarkdown.split(text: blocks.joined(separator: "\n\n"))
      .enumerated().map { index, payload in
        OutboxChunk(
          stepIndex: index,
          chatId: job.origin.chatID,
          payload: payload,
          payloadHash: ContentHash.fnv1a(payload)
        )
      }
  }
}

// MARK: - Result Evidence

private extension CoderCompletionReport {
  func field(_ label: String, _ value: String) -> String {
    CoderCardMarkdown.field(label, redact(value))
  }

  func workspaceEvidence(_ result: CoderResult) -> [String] {
    var blocks = ["### Changes and workspace"]

    if let files = result.changedFiles {
      blocks.append(field("Observed changed files", files.isEmpty ? "none" : "\(files.count)"))
      if !files.isEmpty {
        blocks.append(CoderCardMarkdown.literal(redact(files.joined(separator: "\n"))))
      }
    } else {
      blocks.append(field("Changed-file comparison", "unavailable"))
    }

    blocks.append(field("Workspace", result.workspacePath ?? "unavailable"))
    if let branch = result.branch {
      blocks.append(field("Branch (observed)", branch))
    }

    return blocks
  }

  func publicationEvidence(_ publication: CoderPublication) -> [String] {
    switch publication {
    case .absent:
      [field("Publication", "absent")]
    case .confirmed(let url):
      [field("Pull request (confirmed)", url)]
    case .unknown(let url):
      [field("Publication", "unknown")]
        + (url.map { value in
          [field("Pull request (worker-reported, unconfirmed)", value)]
        } ?? [])
    }
  }

  func checkEvidence(_ checks: [String]) -> [String] {
    ["### Checks (worker-reported)"]
      + (checks.isEmpty
        ? [field("Checks", "not reported")]
        : [CoderCardMarkdown.literal(redact(checks.joined(separator: "\n")))])
  }

  func executionEvidence(_ result: CoderResult) -> [String] {
    let baseline = result.baselineObserved ? "observed" : "worker-reported"
    let startingCommit =
      result.startingCommit
      ?? (result.baselineObserved ? "none (unborn HEAD)" : "unavailable")
    var blocks = [field("Starting commit (\(baseline))", startingCommit)]
    if let commit = result.commit {
      blocks.append(field("Commit (observed)", commit))
    }
    if let author = result.commitAuthor {
      blocks.append(field("Commit author (observed)", author))
    }
    if let actor = result.githubActor {
      blocks.append(field("GitHub actor (confirmed PR)", actor))
    }
    if let usage = result.reportedUsage {
      let values = usage.sorted {
        $0.key < $1.key
      }.map {
        "\($0.key)=\($0.value)"
      }
      blocks.append(field("Usage (worker-reported)", values.joined(separator: "; ")))
    } else {
      blocks.append(field("Usage (worker-reported)", "unavailable"))
    }
    return blocks
  }
}
