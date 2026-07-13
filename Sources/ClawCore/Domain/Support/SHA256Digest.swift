import Crypto
import Foundation

public enum SHA256Digest {
  public static func hex(_ data: Data) -> String {
    hex(digest: SHA256.hash(data: data))
  }

  public static func hex(_ text: String) -> String {
    hex(Data(text.utf8))
  }

  /// Lowercase hex of an already-computed digest (or any byte sequence), so a caller that streams
  /// its own `SHA256` hasher can finish through the same rendering the `Data` overload uses.
  public static func hex(digest: some Sequence<UInt8>) -> String {
    digest.map { byte in
      String(format: "%02x", byte)
    }.joined()
  }
}
