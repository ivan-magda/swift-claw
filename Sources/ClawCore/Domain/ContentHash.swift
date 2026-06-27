/// A deterministic content hash for outbox-chunk dedup. Uses FNV-1a over the UTF-8 bytes because
/// it must be **stable across processes**: the outbox dedups chunks by hash so a redelivery after
/// a crash recognizes an already-enqueued chunk. `String.hashValue` is seeded per-process (for
/// hash-flooding resistance), so it would change across restarts and break that dedup.
public enum ContentHash {
  private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  private static let prime: UInt64 = 0x0000_0100_0000_01b3

  public static func fnv1a(_ text: String) -> String {
    var hash = offsetBasis
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* prime
    }
    return String(hash, radix: 16)
  }
}
