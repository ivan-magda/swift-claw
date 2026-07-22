import ClawCore
import Foundation

/// Loads the vendored `Prices.json` snapshot compiled into the binary (offline-first).
/// Embedded, not a bundle resource: the release binary ships as a single file, and a
/// `Bundle.module` accessor traps when its bundle is not next to the executable.
/// Never crashes — any failure yields `.empty`, leaving the heuristic tier to carry USD.
public enum PriceFileLoader {
  public static func load() -> PriceTable {
    let data = Data(PackageResources.Prices_json)

    guard let prices = try? JSONDecoder().decode([String: ModelPrice].self, from: data) else {
      return .empty
    }

    return PriceTable(prices: prices)
  }
}
