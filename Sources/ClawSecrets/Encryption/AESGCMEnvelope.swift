import Crypto
import Foundation

/// The on-disk AES-GCM envelope shared by both secret stores: `[1-byte version] +
/// AES.GCM.SealedBox.combined` (12-byte random nonce ‖ ciphertext ‖ 16-byte tag). The version byte is
/// bound as AEAD associated data, so it can't be swapped without failing authentication; each store
/// supplies its own associated-data label, which is what keeps the two envelopes under the shared
/// `secret.key` from ever opening as each other.
///
/// One codec, parameterized by `(version, associatedData)`: a future format change is then made once,
/// not copied into two framing implementations that can drift apart under a single key.
package struct AESGCMEnvelope: Sendable {
  /// Cap on the envelope before its plaintext is allocated.
  package static let maximumByteCount = 256 * 1024

  /// The single accepted version. Single-version today; bound as AAD so a future multi-version world
  /// dispatches on it AND authenticates it.
  package let version: UInt8
  /// The AEAD associated data bound under `version`. Held once so the seal and open sides can never
  /// authenticate under different labels.
  package let associatedData: Data

  package init(version: UInt8, associatedData: Data) {
    self.version = version
    self.associatedData = associatedData
  }

  package func seal(_ plaintext: Data, key: SymmetricKey) throws(AESGCMEnvelopeError) -> Data {
    guard
      let sealedBox = try? AES.GCM.seal(plaintext, using: key, authenticating: associatedData),
      let combined = sealedBox.combined
    else {
      throw .sealFailed
    }
    return Data([version]) + combined
  }

  package func open(_ envelope: Data, key: SymmetricKey) throws(AESGCMEnvelopeError) -> Data {
    guard let onDiskVersion = envelope.first else {
      throw .missingVersion
    }
    // Dispatch fails closed before any cryptography: an unknown version is a build that cannot read
    // this file, a distinct fact from a ciphertext that failed its tag.
    guard onDiskVersion == version else {
      throw .unsupportedVersion
    }
    guard
      let sealedBox = try? AES.GCM.SealedBox(combined: Data(envelope.dropFirst())),
      let plaintext = try? AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
    else {
      throw .openFailed
    }
    return plaintext
  }
}

/// The codec's closed failure set. Each store maps these into its own seam error: "unknown version"
/// and "failed tag" carry different remedies to the owner, and one store distinguishes them while the
/// other collapses both, so the taxonomy stays with the store rather than the codec.
package enum AESGCMEnvelopeError: Error {
  case missingVersion
  case unsupportedVersion
  case openFailed
  case sealFailed
}
