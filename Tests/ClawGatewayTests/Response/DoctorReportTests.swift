import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct DoctorReportTests {
  @Test func okWhenAllChecksPass() {
    // given
    var report = DoctorReport()

    // when
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "allowlist.owners", value: "1", ok: true, group: .database)

    // then
    #expect(report.ok)
  }

  @Test func failsIfAnyCheckFails() {
    // given
    var report = DoctorReport()

    // when
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "allowlist.owners", value: "0", ok: false, group: .database)

    // then
    #expect(report.ok == false)
  }

  @Test func textRenderShowsGroupHeaderAndKeys() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)

    // when
    let text = report.renderText()

    // then
    #expect(text.contains("Config"))
    #expect(text.contains("config"))
  }

  @Test func passingGroupRendersRollupWithoutRowMarkers() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "config.max_tokens", value: "4096", group: .config)

    // when
    let text = report.renderText()

    // then
    #expect(text.contains("ok"))
    #expect(!text.contains("✗"))
  }

  @Test func failingRowMarksRowAndGroupHeaderRollup() {
    // given
    var report = DoctorReport()
    report.add(key: "spend.today_usd", value: "0.0", group: .spend)
    report.add(key: "spend.remaining_day_usd", value: "0.00", ok: false, group: .spend)

    // when
    let text = report.renderText()

    // then
    #expect(text.contains("FAIL"))
    #expect(text.contains("✗ spend.remaining_day_usd"))
  }

  @Test func keyColumnIsAlignedPerGroupNotGlobally() {
    // given: a short-key group and a group with a much wider key
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "sandbox.image_digest_ok", value: "true", group: .sandbox)

    // when
    let text = report.renderText()

    // then: the short-key group hugs its own width, not the wide sandbox key's
    #expect(text.contains("    config  OK"))
  }

  @Test func groupsRenderInCanonicalOrderNotInsertionOrder() throws {
    // given
    var report = DoctorReport()
    report.add(key: "sandbox.available", value: "true", group: .sandbox)
    report.add(key: "config", value: "OK", group: .config)

    // when
    let text = report.renderText()

    // then
    let configIndex = try #require(text.range(of: "Config")).lowerBound
    let sandboxIndex = try #require(text.range(of: "Sandbox")).lowerBound
    #expect(configIndex < sandboxIndex)
  }

  @Test func emptyGroupsAreOmitted() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)

    // when
    let text = report.renderText()

    // then
    #expect(text.contains("Config"))
    #expect(!text.contains("Sandbox"))
    #expect(!text.contains("Spend"))
  }

  @Test func llmRunsGroupUsesFriendlyTitleAndSnakeCaseJSON() {
    // given
    var report = DoctorReport()
    report.add(key: "llm.last_success", value: "never", group: .llmRuns)

    // when
    let text = report.renderText()
    let json = report.renderJSON()

    // then
    #expect(text.contains("LLM & Runs"))
    #expect(json.contains("\"llm_runs\""))
  }

  @Test func telegramSummaryReportsHealthyPerGroup() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "db.writable", value: "true", group: .database)

    // when
    let summary = report.renderTelegramSummary()

    // then
    #expect(summary.contains("all systems healthy"))
    #expect(summary.contains("Config: ok"))
    #expect(summary.contains("Database: ok"))
    #expect(!summary.contains("FAIL"))
  }

  @Test func telegramSummaryExpandsFailingRowsUnderTheirGroup() {
    // given
    var report = DoctorReport()
    report.add(key: "spend.today_usd", value: "0.0", group: .spend)
    report.add(key: "spend.remaining_day_usd", value: "0.00", ok: false, group: .spend)

    // when
    let summary = report.renderTelegramSummary()

    // then
    #expect(summary.contains("1 check failing"))
    #expect(summary.contains("Spend: FAIL"))
    #expect(summary.contains("  spend.remaining_day_usd: 0.00"))
  }

  @Test func telegramSummaryPluralizesFailingCount() {
    // given
    var report = DoctorReport()
    report.add(key: "spend.remaining_day_usd", value: "0.00", ok: false, group: .spend)
    report.add(key: "sandbox.net_isolated", value: "false", ok: false, group: .sandbox)

    // when
    let summary = report.renderTelegramSummary()

    // then
    #expect(summary.contains("2 checks failing"))
  }

  @Test func telegramSummaryShowsHeadlineValuesOnHealthyGroupLines() {
    // given — consecutive_failures is dynamic signal, streaming is static config
    var report = DoctorReport()
    report.add(key: "llm.consecutive_failures", value: "3", group: .llmRuns, headline: true)
    report.add(key: "llm.streaming", value: "on", group: .llmRuns)

    // when
    let summary = report.renderTelegramSummary()

    // then — the figure is visible without expanding the group; the short key labels it
    #expect(summary.contains("LLM & Runs: ok · consecutive_failures 3"))
    #expect(!summary.contains("streaming"))
  }

  @Test func telegramSummaryDoesNotRepeatFailingRowsInTheHeadline() {
    // given
    var report = DoctorReport()
    report.add(
      key: "spend.remaining_day_usd",
      value: "0.00",
      ok: false,
      group: .spend,
      headline: true
    )

    // when
    let summary = report.renderTelegramSummary()

    // then — the failing row appears once, as the expanded detail line
    #expect(summary.contains("Spend: FAIL"))
    #expect(summary.contains("  spend.remaining_day_usd: 0.00"))
    #expect(!summary.contains("FAIL · remaining_day_usd"))
  }

  @Test func telegramSummaryTruncatesLongFailingValues() {
    // given
    var report = DoctorReport()
    let longValue = String(repeating: "x", count: 500)
    report.add(key: "sandbox.last_error", value: longValue, ok: false, group: .sandbox)

    // when
    let summary = report.renderTelegramSummary()

    // then
    #expect(!summary.contains(longValue))
    #expect(summary.contains("…"))
  }

  @Test func telegramGroupRendersEveryRowOfThatGroupAndNothingElse() {
    // given
    var report = DoctorReport()
    report.add(key: "db.writable", value: "true", group: .database)
    report.add(key: "mcp", value: "2 configured, 1 enabled", group: .mcp)
    report.add(key: "mcp.linear.tools", value: "7", group: .mcp)

    // when
    let text = report.renderTelegramGroup(.mcp)

    // then — a passing row is shown too: a single-group reply is asked for to read the rows.
    #expect(text.contains("MCP: ok"))
    #expect(text.contains("mcp: 2 configured, 1 enabled"))
    #expect(text.contains("mcp.linear.tools: 7"))
    #expect(text.contains("db.writable") == false)
  }

  @Test func telegramGroupMarksFailingRowsAndTruncatesLongValues() {
    // given
    var report = DoctorReport()
    let longValue = String(repeating: "x", count: 500)
    report.add(key: "mcp.linear.tools", value: longValue, ok: false, group: .mcp)

    // when
    let text = report.renderTelegramGroup(.mcp)

    // then
    #expect(text.contains("MCP: FAIL"))
    #expect(text.contains("✗ mcp.linear.tools"))
    #expect(text.contains(longValue) == false)
    #expect(text.contains("…"))
  }

  @Test func telegramGroupSaysSoWhenTheGroupHasNoRows() {
    // given — a report built before the subsystem reported anything.
    let report = DoctorReport()

    // when / then — an empty string would read as a delivery failure to the owner.
    #expect(report.renderTelegramGroup(.mcp) == "MCP: nothing reported")
  }

  @Test func jsonIncludesGroupAndTopLevelOk() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "spend.remaining_day_usd", value: "0.00", ok: false, group: .spend)

    // when
    let json = report.renderJSON()

    // then
    #expect(json.contains("\"config\""))
    #expect(json.contains("\"group\""))
    #expect(json.contains("\"spend\""))
    #expect(json.contains("\"ok\""))
  }

  @Test func jsonPreservesEverySkillHealthField() throws {
    // given
    let diagnostics = SkillDiagnostics(
      scan: SkillScanResult(
        descriptors: [],
        warnings: [.invalidSkillManifest(skill: "broken")]
      ),
      skillsCap: ContextBudget.default.skillsCap
    )
    var report = DoctorReport()
    report.add(contentsOf: [HealthRowsBuilder.skillsCheck(diagnostics)])

    // when
    let data = try #require(report.renderJSON().data(using: .utf8))
    let payload = try JSONDecoder().decode(DoctorJSONPayload.self, from: data)
    let row = try #require(payload.checks.first { $0.key == "context.skills" })

    // then
    #expect(row.value.contains("accepted=0"))
    #expect(row.value.contains("rejected=1"))
    #expect(row.value.contains("fits_cap=true"))
    #expect(row.ok == false)
    #expect(row.group == .context)
    #expect(row.isHeadline == true)
  }
}

private struct DoctorJSONPayload: Decodable {
  let checks: [DoctorReport.Check]
}
