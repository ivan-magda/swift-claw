import ClawCore
import Testing

@testable import ClawGateway

@Suite struct AllowlistSeedingTests {
  @Test func seedsConfiguredOwnersWhenTheStoreAccepts() {
    // given a store that accepts the seed and one configured owner
    let store = StubAllowlist(allowed: [])

    // when
    let outcome = AllowlistSeeding.seed(into: store, owners: [42])

    // then
    #expect(outcome == .seeded)
  }

  @Test func strandsOwnersWhenSeedFailsWithOwnersConfigured() {
    // given a store whose seed throws and one configured owner
    let store = ThrowingAllowlist()

    // when
    let outcome = AllowlistSeeding.seed(into: store, owners: [42])

    // then — booting locked out must abort, so the failure is fatal and carries the store error
    #expect(outcome == .strandedOwners(.unexpected("boom")))
  }

  @Test func toleratesSeedFailureWhenNoOwnersAreConfigured() {
    // given a store whose seed throws but no owners are configured (onboarding boot)
    let store = ThrowingAllowlist()

    // when
    let outcome = AllowlistSeeding.seed(into: store, owners: [])

    // then — nothing to strand, so an onboarding boot may continue
    #expect(outcome == .toleratedFailure(.unexpected("boom")))
  }
}
