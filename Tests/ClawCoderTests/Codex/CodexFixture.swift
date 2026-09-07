import ClawCore
import Foundation
import Testing

@testable import ClawCoder

struct CodexFixture {
  let git: GitWorkspaceFixture
  let executable: URL

  init() async throws {
    git = try await GitWorkspaceFixture()
    executable = git.root.appendingPathComponent("codex")
    try write(
      "help",
      """
      --json --approve-for-me --config --skip-git-repo-check --ephemeral --color --cd
      --output-schema --output-last-message --profile
      """
    )
    try write(
      "events",
      """
      {"type":"future.event","usage":"unrelated shape"}
      {"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":4}}

      """
    )
    try report()
    try script(
      "codex",
      """
      #!/bin/sh
      set -eu
      root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      if [ "$1" = '--version' ]; then printf 'codex-cli 0.153.4\\n'; exit 0; fi
      if [ "$2" = '--help' ]; then cat "$root/help"; exit 0; fi
      printf '%s\\0' "$@" > "$root/argv"
      env > "$root/environment"
      cat > "$root/stdin"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) shift; result=$1 ;;
          --output-schema) shift; cp "$1" "$root/schema" ;;
        esac
        shift
      done
      if [ -f "$root/action" ]; then /bin/sh "$root/action" "$result"; fi
      if [ ! -f "$root/no-report" ]; then cp "$root/report" "$result"; fi
      if [ -f "$root/quiet" ]; then exit 0; fi
      printf '{"type":'
      printf '"thread.started"}\\n'
      cat "$root/events"
      dd if=/dev/zero bs=1024 count=70 2>/dev/null | tr '\\000' x >&2
      if [ -f "$root/exit" ]; then exit "$(cat "$root/exit")"; fi
      """
    )
  }

  func write(_ name: String, _ value: String) throws {
    try Data(value.utf8).write(to: git.root.appendingPathComponent(name))
  }

  func script(_ name: String, _ value: String) throws {
    try write(name, value)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: git.root.appendingPathComponent(name).path
    )
  }

  func report(_ changes: [String: Any] = [:]) throws {
    var object: [String: Any] = [
      "status": CodexReportStatus.succeeded.rawValue, "summary": "Completed",
      "starting_commit": NSNull(),
      "base_branch": NSNull(), "changed_files": ["invented.txt"], "branch": "invented",
      "commit": NSNull(), "pr_url": NSNull(), "checks": ["reported check"], "error": NSNull(),
    ]
    object.merge(changes) { _, updated in
      updated
    }
    try JSONSerialization.data(withJSONObject: object).write(
      to: git.root.appendingPathComponent("report")
    )
  }

  func backend(
    extraEnvironment: [String: String] = [:],
    profile: String? = nil
  ) throws -> CodexBackend {
    var environment = ["PATH": "\(git.root.path):/usr/bin:/bin", "HOME": git.root.path]
    environment.merge(extraEnvironment) { _, updated in
      updated
    }
    return try CodexBackend(
      config: CoderConfig(
        enabled: true,
        maxConcurrentJobs: 1,
        jobTimeoutSeconds: 30,
        executable: "codex",
        profile: profile,
        configHome: git.root.appendingPathComponent("config").path
      ),
      environment: environment
    )
  }

  func invocation(_ request: CoderRequest? = nil) async throws -> CoderInvocation {
    let prepared = try await CoderRequestPreparer(executionPolicyID: "fixture").prepare(
      request ?? git.request()
    )
    return git.invocation(prepared)
  }

  func read(_ name: String) throws -> String {
    try String(contentsOf: git.root.appendingPathComponent(name), encoding: .utf8)
  }
}
