/// Deterministic content hashes for outbox-chunk deduplication across process restarts.
public enum ContentHash {
  private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  private static let prime: UInt64 = 0x0000_0100_0000_01b3

  /// Returns the 64-bit FNV-1a hash of the text's UTF-8 bytes as unpadded lowercase hexadecimal.
  public static func fnv1a(_ text: String) -> String {
    var hash = offsetBasis
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* prime
    }
    return String(hash, radix: 16)
  }
}
