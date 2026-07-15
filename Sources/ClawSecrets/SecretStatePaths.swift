import ClawCore
import Foundation

/// The only production source of state-root-relative secret paths.
///
/// It takes a state root and nothing else. There is no member that turns a caller-supplied name
/// into a URL, so no store built on it — and no CLI flow driving one — can be pointed at a foreign
/// file such as another vendor's home directory or an exported auth blob. The absence of an import
/// path is a property of the type rather than a promise buried in control flow.
public struct SecretStatePaths: Sendable, Equatable {
  /// The 32-byte symmetric key protecting both envelopes. Mode 0600, owner-only.
  public static let keyName = SecretFile.key
  /// The runtime secrets the daemon boots on: the Telegram token plus the optional LLM and search
  /// keys.
  public static let runtimeEnvelopeName = SecretFile.envelope
  /// The provider-keyed OAuth credential map, encrypted under the same key as the runtime envelope.
  /// Its associated data is distinct from that envelope's, so the two cannot be swapped: either one
  /// moved to the other's name fails authentication instead of opening as the wrong kind of secret.
  public static let credentialEnvelopeName = "llm-credentials.enc"
  /// The daemon instance lock, named here so one type names every state-root entry the secret layer
  /// touches. Today only `clawd run` acquires it.
  public static let instanceLockName = "clawd.lock"

  private let stateRoot: URL

  public init(stateRoot: URL) {
    self.stateRoot = stateRoot
  }

  public var key: URL { stateRoot.appendingPathComponent(Self.keyName) }
  public var runtimeEnvelope: URL { stateRoot.appendingPathComponent(Self.runtimeEnvelopeName) }
  public var credentialEnvelope: URL {
    stateRoot.appendingPathComponent(Self.credentialEnvelopeName)
  }
  public var instanceLock: URL { stateRoot.appendingPathComponent(Self.instanceLockName) }

  /// The directory every entry above is renamed within — the fsync target that makes a rename
  /// durable, and the only directory publication ever opens.
  public var directory: URL { stateRoot }
}
