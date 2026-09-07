import ClawCore
import Foundation

struct CoderWorkspaceState: Sendable {
  let directory: String
  let baseline: RepositoryInventory?
  let startingCommit: String?
}

struct CoderWorkspace: Sendable {
  func prepare(
    _ invocation: CoderInvocation,
    deadline: ContinuousClock.Instant? = nil,
    recordProcess: @Sendable @escaping (CoderProcessEvent) async throws -> Void
  ) async throws -> CoderWorkspaceState {
    let git = CoderGit(
      tracking: .job(record: recordProcess),
      phase: .prepare,
      deadline: deadline ?? ContinuousClock.now.advanced(by: invocation.timeout)
    )
    try Task.checkCancellation()
    let jobDirectory = URL(fileURLWithPath: invocation.jobDirectory)
    try PrivateDirectory.ensure(at: jobDirectory)
    let prepared = invocation.prepared
    guard let source = prepared.checkoutPath else {
      let destination = jobDirectory.appendingPathComponent("repository")
      try PrivateDirectory.ensure(at: destination)
      guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
        throw CoderError.unavailable("Remote Coder destination must be empty.")
      }
      return CoderWorkspaceState(directory: destination.path, baseline: nil, startingCommit: nil)
    }
    let identity = try await CoderRequestPreparer.localIdentity(at: source, git: git)
    guard identity.checkout == source, identity.common == prepared.commonGitDirectory else {
      throw CoderError.staleApproval
    }
    if prepared.request.deliverable == .pullRequest {
      let origin = try await CoderRequestPreparer.publicationOrigin(at: source, git: git)
      guard origin == prepared.publicationRepository else {
        throw CoderError.staleApproval
      }
    }
    let startingCommit: String?
    let directory: String
    if prepared.request.workspace == .inPlace {
      startingCommit = try await inPlaceCommit(at: source, git: git)
      directory = source
    } else {
      let resolved = try await git.commit(prepared.request.startRef ?? "HEAD", at: source)
      startingCommit = resolved
      directory = jobDirectory.appendingPathComponent("repository").path
      try await prepareCopy(
        from: source,
        at: directory,
        commit: resolved,
        publication: prepared.publicationRepository,
        git: git
      )
    }
    let baseline: RepositoryInventory?
    do {
      baseline = try await RepositoryInventory.capture(at: directory, git: git)
    } catch RepositoryInventory.Failure.unavailable {
      baseline = nil
    } catch CoderGitFailure.command {
      baseline = nil
    } catch CoderGitFailure.output {
      baseline = nil
    }
    return CoderWorkspaceState(
      directory: directory,
      baseline: baseline,
      startingCommit: startingCommit
    )
  }
}

// MARK: - Independent copy

private extension CoderWorkspace {
  func prepareCopy(
    from source: String,
    at directory: String,
    commit: String,
    publication: String?,
    git: CoderGit
  ) async throws {
    let destination = URL(fileURLWithPath: directory)
    try PrivateDirectory.ensure(at: destination)
    guard try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty else {
      throw CoderError.unavailable("Separate Coder destination must be empty.")
    }
    try await git.run(
      ["clone", "--no-local", "--no-hardlinks", "--template=", "--", source, directory],
      at: destination.deletingLastPathComponent().path
    )
    try await git.run(["fetch", "--no-tags", "--", source, commit], at: directory)
    try await git.run(["remote", "remove", "origin"], at: directory)
    if let publication {
      try await git.run(
        ["remote", "add", "origin", "https://github.com/\(publication).git"],
        at: directory
      )
    }
    try await git.run(["checkout", "--detach", commit, "--"], at: directory)
    guard try await git.commit("HEAD", at: directory) == commit else {
      throw CoderError.unavailable("Separate Coder checkout does not match its resolved commit.")
    }
  }
}

// MARK: - Starting commit evidence

private extension CoderWorkspace {
  func inPlaceCommit(at directory: String, git: CoderGit) async throws -> String? {
    do {
      return try await git.commit("HEAD", at: directory)
    } catch CoderGitFailure.command(let failedHead) {
      let ref = try await git.text(["symbolic-ref", "--quiet", "HEAD"], at: directory)
      guard ref.hasPrefix("refs/heads/") else {
        throw CoderGitFailure.command(failedHead)
      }
      do {
        try await git.run(["show-ref", "--verify", "--quiet", "--", ref], at: directory)
      } catch CoderGitFailure.command(let absentRef) where absentRef.exitCode == 1 {
        return nil
      }
      throw CoderGitFailure.command(failedHead)
    }
  }
}
