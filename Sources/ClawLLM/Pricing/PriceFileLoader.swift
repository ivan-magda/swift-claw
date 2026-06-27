import ClawCore
import Foundation

/// Loads the vendored `Prices.json` snapshot from `Bundle.module` (offline-first).
/// Never crashes — any failure yields `.empty`, leaving the heuristic tier to carry USD.
public enum PriceFileLoader {
  public static func load() -> PriceTable {
    guard
      let url = Bundle.module.url(forResource: "Prices", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let prices = try? JSONDecoder().decode([String: ModelPrice].self, from: data)
    else {
      return .empty
    }
    return PriceTable(prices: prices)
  }
}
