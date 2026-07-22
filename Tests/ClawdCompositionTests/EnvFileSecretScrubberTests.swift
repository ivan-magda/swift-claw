import ClawTestSupport
import Foundation
import Testing

@testable import clawd

@Suite struct EnvFileSecretScrubberTests {
  @Test func blanksOnlyTheListedSecretKeysAndKeepsEverythingElse() {
    // given — an env file with secrets, comments, and non-secret assignments
    let contents = """
      # --- SECRETS ---
      CLAW_TELEGRAM_BOT_TOKEN=123456:real-token
      CLAW_ALLOWLIST=12345678
      export CLAW_LLM_API_KEY=sk-live-key
        CLAW_SEARCH_API_KEY=exa-key
      CLAW_LLM_MODEL=claude-sonnet-4-6
      """

    // when
    let result = EnvFileSecretScrubber.scrub(
      contents: contents,
      keys: ["CLAW_TELEGRAM_BOT_TOKEN", "CLAW_LLM_API_KEY", "CLAW_SEARCH_API_KEY"]
    )

    // then — secret values are blanked in place; structure, comments, other keys untouched
    #expect(
      result.contents == """
        # --- SECRETS ---
        CLAW_TELEGRAM_BOT_TOKEN=
        CLAW_ALLOWLIST=12345678
        export CLAW_LLM_API_KEY=
          CLAW_SEARCH_API_KEY=
        CLAW_LLM_MODEL=claude-sonnet-4-6
        """
    )
    #expect(
      result.scrubbedKeys == [
        "CLAW_TELEGRAM_BOT_TOKEN", "CLAW_LLM_API_KEY", "CLAW_SEARCH_API_KEY",
      ]
    )
  }

  @Test func reportsNothingScrubbedWhenValuesAreAlreadyBlankOrKeysAbsent() {
    // given — secrets already blank or missing entirely
    let contents = """
      CLAW_TELEGRAM_BOT_TOKEN=
      CLAW_LLM_MODEL=claude-sonnet-4-6
      """

    // when
    let result = EnvFileSecretScrubber.scrub(
      contents: contents,
      keys: ["CLAW_TELEGRAM_BOT_TOKEN", "CLAW_LLM_API_KEY", "CLAW_SEARCH_API_KEY"]
    )

    // then — the file is returned unchanged and no keys are reported
    #expect(result.contents == contents)
    #expect(result.scrubbedKeys.isEmpty)
  }
}

@Suite struct SealScrubFileTests {
  @Test func scrubsTheFileInPlacePreservingMode0600() throws {
    // given — a 0600 env file holding real-looking secrets
    let dir = try makeTemporaryRoot(prefix: "claw-scrub")
    defer { try? FileManager.default.removeItem(at: dir) }
    let filePath = dir.appendingPathComponent("clawd.env").path
    try "CLAW_TELEGRAM_BOT_TOKEN=123:abc\nCLAW_LLM_MODEL=m\n"
      .write(toFile: filePath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)

    // when
    let outcome = SecretsCommand.Seal.scrubEnvFile(
      at: filePath,
      keys: ["CLAW_TELEGRAM_BOT_TOKEN"]
    )

    // then — value blanked, mode preserved, outcome names the key
    #expect(outcome == .scrubbed(keys: ["CLAW_TELEGRAM_BOT_TOKEN"], path: filePath))
    let rewritten = try String(contentsOfFile: filePath, encoding: .utf8)
    #expect(rewritten == "CLAW_TELEGRAM_BOT_TOKEN=\nCLAW_LLM_MODEL=m\n")
    let mode = try FileManager.default.attributesOfItem(atPath: filePath)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o600)
  }

  @Test func absentFileYieldsFileAbsentNotAnError() {
    // given / when
    let outcome = SecretsCommand.Seal.scrubEnvFile(
      at: "/nonexistent/clawd.env",
      keys: ["CLAW_TELEGRAM_BOT_TOKEN"]
    )

    // then
    #expect(outcome == .fileAbsent(path: "/nonexistent/clawd.env"))
  }

  @Test func summaryWarnsLoudlyWhenScrubFailed() {
    // given / when — a failed scrub must tell the user plaintext is still on disk
    let summary = SecretsCommand.Seal.sealSummary(
      envelopePath: "/root/secrets.enc",
      keyPath: "/root/secret.key",
      scrubOutcome: .failed(path: "/root/clawd.env", reason: "permission denied")
    )

    // then
    #expect(summary.contains("WARNING"))
    #expect(summary.contains("still in /root/clawd.env"))
  }
}
