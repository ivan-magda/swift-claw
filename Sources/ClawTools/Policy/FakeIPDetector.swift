import ClawCore
import Foundation

/// The outcome of one fresh fake-IP canary probe.
public enum FakeIPDetection: Sendable, Equatable {
  /// DNS interception confirmed: every canary answered from the benchmarking range.
  /// `sample` is one observed pool address, for diagnostics.
  case active(sample: ResolvedAddress)
  case inactive
}

/// The probe seam: lets the fetch path and doctor ask "is a fake-IP proxy rewriting DNS right
/// now?" while tests script the answer.
public protocol FakeIPDetecting: Sendable {
  func detect() async -> FakeIPDetection
}

/// Behavioral fake-IP fingerprinting. A fake-IP VPN/proxy (mihomo/Clash, sing-box, Surge-style)
/// intercepts DNS and answers every query from a synthetic pool inside `198.18.0.0/15` — even
/// for names that do not exist. So: resolve known-public hosts plus one random nonexistent host;
/// only if ALL of them collapse into the benchmarking range is fake-IP mode confirmed. Any
/// real answer, NXDOMAIN, or resolver failure means no confirmation — the caller stays strict.
public struct FakeIPDetector: FakeIPDetecting {
  private let resolver: any AddressResolving
  private let publicCanaryHosts: [String]
  private let makeNonexistentHost: @Sendable () -> String

  public init(
    resolver: any AddressResolving,
    publicCanaryHosts: [String] = FakeIPDetector.defaultPublicCanaryHosts,
    makeNonexistentHost: @escaping @Sendable () -> String = FakeIPDetector.randomNonexistentHost
  ) {
    self.resolver = resolver
    self.publicCanaryHosts = publicCanaryHosts
    self.makeNonexistentHost = makeNonexistentHost
  }

  /// Stable, benign, unrelated-operator hosts that always have public A records.
  public static let defaultPublicCanaryHosts = ["example.com", "cloudflare.com"]

  /// A random label under a domain with no wildcard: guaranteed NXDOMAIN on real DNS, yet a
  /// fake-IP resolver fabricates an answer for it — the discriminating half of the fingerprint.
  public static func randomNonexistentHost() -> String {
    let randomLabel = UUID().uuidString.lowercased().prefix(12)
    return "claw-probe-\(randomLabel).example.com"
  }

  public func detect() async -> FakeIPDetection {
    var sample: ResolvedAddress?

    for host in publicCanaryHosts + [makeNonexistentHost()] {
      guard
        let addresses = try? await resolver.resolve(host: host),
        addresses.isEmpty == false,
        addresses.allSatisfy({ address in SSRFGuard.benchmarkRange.contains(address) })
      else {
        return .inactive
      }
      sample = sample ?? addresses.first
    }

    guard let sample else {
      return .inactive
    }
    return .active(sample: sample)
  }
}
