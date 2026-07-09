import ClawCore
import Testing

@testable import ClawGateway

@Suite struct ApprovalsHealthTests {
  private func value(_ rows: [ApprovalsHealthRows.Row], _ key: String) -> String? {
    rows.first { row in row.key == key }?.value
  }

  @Test func noPendingApprovalsRendersZeroAndNone() {
    // given — a freshly-migrated approvals table: nothing pending
    let health = ApprovalsHealth(pendingCount: 0, oldestPendingAgeSeconds: nil)

    // when
    let rows = ApprovalsHealthRows.rows(health: health, approvalExpirySeconds: 3600)

    // then
    #expect(value(rows, "approvals.pending") == "0")
    #expect(value(rows, "approvals.oldest_age_s") == "none")
  }

  @Test func pendingApprovalsRenderCountAndOldestAgeAgainstTheExpiry() {
    // given — two pending approvals, the oldest 900s into its 3600s window
    let health = ApprovalsHealth(pendingCount: 2, oldestPendingAgeSeconds: 900)

    // when
    let rows = ApprovalsHealthRows.rows(health: health, approvalExpirySeconds: 3600)

    // then — age/expiry mirrors the heartbeat.today count/cap idiom (spec §4.6)
    #expect(value(rows, "approvals.pending") == "2")
    #expect(value(rows, "approvals.oldest_age_s") == "900/3600")
  }
}
