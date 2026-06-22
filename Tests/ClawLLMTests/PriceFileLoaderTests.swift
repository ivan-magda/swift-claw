import Testing

@testable import ClawCore
@testable import ClawLLM

@Suite struct PriceFileLoaderTests {
  @Test func loadsVendoredPricesWithoutCrashing() {
    // when
    let table = PriceFileLoader.load()

    // then — the vendored snapshot resolves to a non-empty table
    #expect(table.prices.isEmpty == false)
    #expect(table.price(for: "gpt-4o") != nil)
  }
}
