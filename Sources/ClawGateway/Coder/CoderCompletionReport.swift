import ClawCore

public struct CoderCompletionReport: Sendable {
  private let redact: @Sendable (String) -> String

  public init(redact: @escaping @Sendable (String) -> String) {
    self.redact = redact
  }

  public func chunks(job: CoderJob, result: CoderResult) -> [OutboxChunk] {
    var lines = ["Coder \(job.id.uuidString): \(result.state.rawValue)", result.summary]
    lines += workspaceEvidence(result)
    lines += publicationEvidence(result.publication)
    lines += executionEvidence(result)
    if job.ownership != .none && job.ownership != .stopped {
      lines.append(
        "Process ownership unresolved; reservation retained. Operator recovery required."
      )
    }
    return ReplySplitter.split(text: redact(lines.joined(separator: "\n")))
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
  func workspaceEvidence(_ result: CoderResult) -> [String] {
    var lines: [String] = []
    if let path = result.workspacePath { lines.append("Workspace: \(path)") }
    if let start = result.startingCommit {
      let evidence = result.baselineObserved ? "observed" : "worker-reported"
      lines.append("Starting commit (\(evidence)): \(start)")
    }
    if let files = result.changedFiles {
      lines.append(
        "Observed changed files: \(files.isEmpty ? "none" : files.joined(separator: ", "))"
      )
    } else {
      lines.append("Changed-file comparison: unavailable")
    }
    if let branch = result.branch { lines.append("Branch: \(branch)") }
    if let commit = result.commit { lines.append("Commit: \(commit)") }
    return lines
  }

  func publicationEvidence(_ publication: CoderPublication) -> [String] {
    var lines: [String] = []
    switch publication {
    case .absent: lines.append("Publication: absent")
    case .confirmed(let url): lines.append("Publication confirmed: \(url)")
    case .unknown(let url):
      lines.append(
        "Publication: unknown"
          + (url.map {
            "; worker reported \($0)"
          } ?? "")
      )
    }
    return lines
  }

  func executionEvidence(_ result: CoderResult) -> [String] {
    var lines: [String] = []
    if !result.reportedChecks.isEmpty {
      lines.append("Worker-reported checks: \(result.reportedChecks.joined(separator: "; "))")
    }
    if let usage = result.reportedUsage {
      let fields = usage.sorted {
        $0.key < $1.key
      }.map {
        "\($0.key)=\($0.value)"
      }
      lines.append("Worker-reported usage: \(fields.joined(separator: ", "))")
    } else {
      lines.append("Worker-reported usage: unavailable")
    }
    if let author = result.commitAuthor { lines.append("Commit author: \(author)") }
    if let actor = result.githubActor { lines.append("GitHub actor: \(actor)") }
    if let failure = result.failure {
      lines.append("Failure (\(failure.stage.rawValue)): \(failure.message)")
    }
    return lines
  }
}
