import Foundation
import Testing

@testable import ClawCoder

@Suite struct CodexAuthenticationTests {
  @Test func localStatusDistinguishesMissingLoginAndUnverifiableProfile() async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    try fixture.script(
      "codex",
      """
      #!/bin/sh
      [ "$1" = login ] && [ "$2" = status ] || exit 9
      echo 'Not logged in' >&2
      exit 1
      """
    )

    // when
    let missing = try await fixture.backend().authenticationStatus()
    let profile = try await fixture.backend(profile: "coding").authenticationStatus()
    try fixture.script(
      "codex",
      """
      #!/bin/sh
      [ "$1" = login ] && [ "$2" = status ] || exit 9
      echo 'sensitive-output-must-not-be-rendered'
      exit 0
      """
    )
    let present = try await fixture.backend().authenticationStatus()
    try fixture.script(
      "codex",
      """
      #!/bin/sh
      echo 'config error: task7-sensitive-token' >&2
      exit 1
      """
    )
    let unreadable = try await fixture.backend().authenticationStatus()

    // then
    #expect(missing == .missing)
    #expect(profile == .profileUnverified)
    #expect(present == .authenticated)
    #expect(unreadable == .unavailable)
  }
}
