import Testing

@testable import ClawCore

@Suite struct CoderExecutionPolicyTests {
  @Test func everyResolvedExecutionFactChangesTheIdentity() {
    // given
    let original = policy()
    let changes = [
      policy(executable: "/other/codex"), policy(profile: "review"), policy(profile: nil),
      policy(configHome: "/other/home"), policy(configHome: nil),
      policy(approvalPolicy: "other"), policy(sources: ["github": "GITHUB_TOKEN"]),
      policy(sources: ["other": "GH_TOKEN"]), policy(sources: [:]),
    ]

    // when / then
    for changed in changes { #expect(changed.id != original.id) }
  }

  @Test func credentialSourceOrderDoesNotChangeIdentity() {
    // given
    let first = policy(sources: ["github": "GH_TOKEN", "codex": "/config/auth"])
    let second = policy(sources: ["codex": "/config/auth", "github": "GH_TOKEN"])

    // when / then
    #expect(first.id == second.id)
  }
}

private extension CoderExecutionPolicyTests {
  func policy(
    executable: String = "/bin/codex",
    profile: String? = "default",
    configHome: String? = "/config",
    approvalPolicy: String = "on-request",
    sources: [String: String] = ["github": "GH_TOKEN"]
  ) -> CoderExecutionPolicy {
    CoderExecutionPolicy(
      executable: executable,
      profile: profile,
      configHome: configHome,
      approvalPolicy: approvalPolicy,
      credentialSources: sources
    )
  }
}
