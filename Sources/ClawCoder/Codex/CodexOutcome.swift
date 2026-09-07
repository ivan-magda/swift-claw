import ClawCore
import Foundation

// swiftlint:disable discouraged_optional_collection
struct CodexOutcome {
  var state = CoderJobState.failed
  var workspace: CoderWorkspaceState?
  var localStartObserved = false
  var report: CodexReport?
  var changedFiles: [String]?
  var branch: String?
  var commit: String?
  var commitAuthor: String?
  var githubActor: String?
  var publication = CoderPublication.absent
  var usage: [String: Int]?
  var failure: CoderFailure?

  mutating func fail(_ stage: CoderFailureStage, _ message: String) {
    failure = CoderFailure(stage: stage, message: message)
    if state != .cancelled && state != .timedOut { state = .failed }
  }

  mutating func stopIfNeeded(deadline: ContinuousClock.Instant) {
    guard state != .cancelled, state != .timedOut else {
      return
    }
    if Task.isCancelled {
      state = .cancelled
    } else if ContinuousClock.now >= deadline {
      state = .timedOut
    }
  }

  mutating func retainWorkspaceIfPresent(_ invocation: CoderInvocation) {
    guard workspace == nil, invocation.prepared.request.workspace == .separate else {
      return
    }
    let destination = URL(fileURLWithPath: invocation.jobDirectory)
      .appendingPathComponent("repository").path
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destination, isDirectory: &directory),
      directory.boolValue
    else {
      return
    }
    workspace = CoderWorkspaceState(directory: destination, baseline: nil, startingCommit: nil)
  }

  func result(redactor: SecretRedactor) -> CoderResult {
    func clean(_ text: String) -> String {
      let redacted = redactor.redact(text)
      let safe = String(
        redacted.unicodeScalars.filter {
          !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
      )
      return String(safe.prefix(4096))
    }
    let publication: CoderPublication
    switch self.publication {
    case .absent: publication = .absent
    case .confirmed(let url): publication = .confirmed(url: clean(url))
    case .unknown(let url): publication = .unknown(reportedURL: url.map(clean))
    }
    let starting =
      localStartObserved ? workspace?.startingCommit : report?.startingCommit
    return CoderResult(
      state: state,
      summary: clean(report?.summary ?? failure?.message ?? "Coder task stopped."),
      workspacePath: workspace?.directory,
      startingCommit: starting.map(clean),
      baselineObserved: localStartObserved,
      changedFiles: changedFiles?.map(clean),
      branch: branch.map(clean),
      commit: commit.map(clean),
      publication: publication,
      reportedChecks: Array((report?.checks ?? []).prefix(100)).map(clean),
      reportedUsage: usage,
      commitAuthor: commitAuthor.map(clean),
      githubActor: githubActor.map(clean),
      failure: failure.map {
        CoderFailure(stage: $0.stage, message: clean($0.message))
      }
    )
  }
}
// swiftlint:enable discouraged_optional_collection
