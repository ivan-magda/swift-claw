import Dispatch
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// A resolved IP address in a checkable form. `.ipv4` is host byte order; `.ipv6` is the 16 raw
/// bytes.
public enum ResolvedAddress: Sendable, Equatable {
  case ipv4(UInt32)
  case ipv6([UInt8])

  /// Parses a textual IPv4/IPv6 literal via `inet_pton`; nil for anything else.
  public static func parse(_ text: String) -> ResolvedAddress? {
    var v4Address = in_addr()
    if inet_pton(AF_INET, text, &v4Address) == 1 {
      return .ipv4(UInt32(bigEndian: v4Address.s_addr))
    }

    var v6Address = in6_addr()
    if inet_pton(AF_INET6, text, &v6Address) == 1 {
      let bytes = withUnsafeBytes(of: &v6Address) { raw in Array(raw) }
      return .ipv6(bytes)
    }

    return nil
  }
}

/// The pure classifier: is this address safe to connect to from the daemon? The blocklist is
/// a pinned table; every range has a test row. IPv4-mapped IPv6 is unwrapped and the
/// embedded v4 re-checked.
public enum SSRFGuard {
  public static func isPublic(_ address: ResolvedAddress) -> Bool {
    switch address {
    case .ipv4(let value):
      isPublicV4(value)
    case .ipv6(let bytes):
      isPublicV6(bytes)
    }
  }
}

// MARK: - IPv4

private extension SSRFGuard {
  /// (network, mask) pairs, host byte order. Matching is `value & mask == network`.
  static let blockedV4Ranges: [(network: UInt32, mask: UInt32)] = [
    (v4(0, 0, 0, 0), mask(8)),  // "this network" + unspecified
    (v4(10, 0, 0, 0), mask(8)),  // RFC-1918
    (v4(100, 64, 0, 0), mask(10)),  // CGNAT
    (v4(127, 0, 0, 0), mask(8)),  // loopback
    (v4(169, 254, 0, 0), mask(16)),  // link-local (incl. 169.254.169.254)
    (v4(172, 16, 0, 0), mask(12)),  // RFC-1918
    (v4(192, 0, 0, 0), mask(24)),  // IETF protocol assignments
    (v4(192, 0, 2, 0), mask(24)),  // TEST-NET-1
    (v4(192, 168, 0, 0), mask(16)),  // RFC-1918
    (v4(198, 18, 0, 0), mask(15)),  // benchmarking
    (v4(198, 51, 100, 0), mask(24)),  // TEST-NET-2
    (v4(203, 0, 113, 0), mask(24)),  // TEST-NET-3
    (v4(224, 0, 0, 0), mask(4)),  // multicast
    (v4(240, 0, 0, 0), mask(4)),  // reserved (incl. 255.255.255.255 broadcast)
  ]

  static func isPublicV4(_ value: UInt32) -> Bool {
    !blockedV4Ranges.contains { range in
      value & range.mask == range.network
    }
  }

  static func v4(
    _ byte0: UInt32,
    _ byte1: UInt32,
    _ byte2: UInt32,
    _ byte3: UInt32
  ) -> UInt32 {
    (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
  }

  static func mask(_ prefixLength: UInt32) -> UInt32 {
    prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
  }

  /// The IPv4 address embedded in the final four bytes of an IPv6 address (mapped/NAT64/compatible).
  static func embeddedV4(_ bytes: [UInt8]) -> UInt32 {
    v4(UInt32(bytes[12]), UInt32(bytes[13]), UInt32(bytes[14]), UInt32(bytes[15]))
  }
}

// MARK: - IPv6

private extension SSRFGuard {
  static func isPublicV6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else {
      return false  // malformed: fail closed
    }

    // IPv4-mapped (::ffff:a.b.c.d): unwrap and re-check the embedded v4.
    if bytes[0...9].allSatisfy({ byte in byte == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
      return isPublicV4(embeddedV4(bytes))
    }
    // NAT64 well-known prefix 64:ff9b::/96 (RFC 6052): a DNS64/NAT64 translator forwards to the
    // embedded v4, so classify by that v4 — else 64:ff9b::7f00:1 reaches 127.0.0.1 on such a network.
    let isNAT64 =
      bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
      && bytes[4...11].allSatisfy { byte in byte == 0 }
    if isNAT64 {
      return isPublicV4(embeddedV4(bytes))
    }
    // IPv4-compatible ::a.b.c.d (::/96, deprecated): unwrap the embedded v4. This also subsumes the
    // unspecified :: (→ 0.0.0.0) and loopback ::1 (→ 0.0.0.1), both refused by the v4 blocklist.
    if bytes[0...11].allSatisfy({ byte in byte == 0 }) {
      return isPublicV4(embeddedV4(bytes))
    }
    // link-local fe80::/10
    if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
      return false
    }
    // ULA fc00::/7
    if bytes[0] & 0xFE == 0xFC {
      return false
    }
    // multicast ff00::/8
    if bytes[0] == 0xFF {
      return false
    }
    // documentation 2001:db8::/32
    if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
      return false
    }

    return true
  }
}

/// The DNS seam: keeps `SSRFGuard` pure and lets fetch tests script resolutions.
public protocol AddressResolving: Sendable {
  func resolve(host: String) async throws -> [ResolvedAddress]
}

public enum AddressResolutionError: Error, Sendable, Equatable {
  case unresolvable(host: String)
}

/// The system resolver via `getaddrinfo` — works on macOS and Linux behind the one seam.
/// `getaddrinfo` is a BLOCKING syscall that never observes cancellation, so it runs on a
/// Dispatch worker thread, not the cooperative pool: after the tool timeout abandons this task,
/// a stalled resolve must not pin one of the pool's fixed threads for its OS-level retry window
/// (commonly 30 s–2 min against a DNS blackhole).
public struct SystemAddressResolver: AddressResolving {
  public init() {}

  public func resolve(host: String) async throws -> [ResolvedAddress] {
    // A literal IP needs no lookup (and must not hit DNS).
    if let literal = ResolvedAddress.parse(host) {
      return [literal]
    }

    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try Self.blockingResolve(host: host) })
      }
    }
  }

  private static func blockingResolve(host: String) throws -> [ResolvedAddress] {
    var hints = addrinfo()
    #if canImport(Glibc)
      // Glibc types SOCK_STREAM as the `__socket_type` enum; ai_socktype is a plain CInt.
      hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
      hints.ai_socktype = SOCK_STREAM  // Darwin already types SOCK_STREAM as Int32.
    #endif

    var results: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &results)
    defer {
      if let results {
        freeaddrinfo(results)
      }
    }
    guard status == 0, results != nil else {
      throw AddressResolutionError.unresolvable(host: host)
    }

    var addresses: [ResolvedAddress] = []
    var cursor = results

    while let info = cursor {
      if info.pointee.ai_family == AF_INET, let rawAddress = info.pointee.ai_addr {
        rawAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
          addresses.append(.ipv4(UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)))
        }
      } else if info.pointee.ai_family == AF_INET6, let rawAddress = info.pointee.ai_addr {
        rawAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
          var v6Address = pointer.pointee.sin6_addr
          let bytes = withUnsafeBytes(of: &v6Address) { raw in Array(raw) }
          addresses.append(.ipv6(bytes))
        }
      }
      cursor = info.pointee.ai_next
    }

    guard addresses.isEmpty == false else {
      throw AddressResolutionError.unresolvable(host: host)
    }

    return addresses
  }
}
