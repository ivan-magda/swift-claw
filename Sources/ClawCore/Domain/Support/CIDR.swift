import Foundation

/// An IP network in CIDR notation (`198.18.0.0/15`, `fc00::/18`) — the typed form of an
/// owner-configured network exemption. Parsing normalizes host bits so equal blocks compare
/// equal. Matching is strict per address family: an IPv4-mapped IPv6 form never matches a v4
/// block, so an exotic mapped answer fails closed at the seam that checks it.
public struct CIDR: Sendable, Equatable {
  public let network: ResolvedAddress
  public let prefixLength: Int

  /// Parses `<address>/<prefix-length>`; nil for anything malformed or out of prefix bounds.
  public static func parse(_ text: String) -> CIDR? {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      let address = ResolvedAddress.parse(String(parts[0])),
      let prefixLength = Int(parts[1])
    else {
      return nil
    }

    switch address {
    case .ipv4(let value):
      guard (0...32).contains(prefixLength) else {
        return nil
      }
      return CIDR(network: .ipv4(value & v4Mask(prefixLength)), prefixLength: prefixLength)
    case .ipv6(let bytes):
      guard (0...128).contains(prefixLength) else {
        return nil
      }
      return CIDR(network: .ipv6(maskedV6(bytes, prefixLength)), prefixLength: prefixLength)
    }
  }

  public func contains(_ address: ResolvedAddress) -> Bool {
    switch (network, address) {
    case (.ipv4(let networkValue), .ipv4(let value)):
      value & CIDR.v4Mask(prefixLength) == networkValue
    case (.ipv6(let networkBytes), .ipv6(let bytes)):
      bytes.count == 16 && CIDR.maskedV6(bytes, prefixLength) == networkBytes
    default:
      false
    }
  }
}

extension CIDR: CustomStringConvertible {
  public var description: String {
    "\(network)/\(prefixLength)"
  }
}

// MARK: - Bit Masking

private extension CIDR {
  static func v4Mask(_ prefixLength: Int) -> UInt32 {
    prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
  }

  static func maskedV6(_ bytes: [UInt8], _ prefixLength: Int) -> [UInt8] {
    var masked = [UInt8](repeating: 0, count: 16)
    let fullBytes = prefixLength / 8
    let remainderBits = prefixLength % 8

    for index in 0..<fullBytes {
      masked[index] = bytes[index]
    }
    if remainderBits > 0, fullBytes < 16 {
      masked[fullBytes] = bytes[fullBytes] & (~UInt8(0) << (8 - remainderBits))
    }
    return masked
  }
}
