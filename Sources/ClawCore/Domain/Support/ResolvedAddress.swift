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

extension ResolvedAddress: CustomStringConvertible {
  /// The canonical textual form (dotted-quad v4 / RFC 5952 compressed v6) via `inet_ntop`,
  /// for owner-facing diagnostics such as refusal messages.
  public var description: String {
    switch self {
    case .ipv4(let value):
      var raw = in_addr(s_addr: value.bigEndian)
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
        return "invalid-ipv4"
      }
      return buffer.withUnsafeBufferPointer { pointer in
        guard let base = pointer.baseAddress else {
          return "invalid-ipv4"
        }
        return String(cString: base)
      }
    case .ipv6(let bytes):
      guard bytes.count == 16 else {
        return "invalid-ipv6"
      }
      var raw = in6_addr()
      withUnsafeMutableBytes(of: &raw) { destination in
        destination.copyBytes(from: bytes)
      }
      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
        return "invalid-ipv6"
      }
      return buffer.withUnsafeBufferPointer { pointer in
        guard let base = pointer.baseAddress else {
          return "invalid-ipv6"
        }
        return String(cString: base)
      }
    }
  }
}
