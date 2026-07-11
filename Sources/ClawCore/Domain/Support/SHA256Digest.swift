import Crypto
import Foundation

public enum SHA256Digest {
  public static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { byte in
      String(format: "%02x", byte)
    }.joined()
  }

  public static func hex(_ text: String) -> String {
    hex(Data(text.utf8))
  }
}
