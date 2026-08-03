import ClawCore
import Foundation

/// The sealed credential maps that live under the state root, as a closed set. A store names one of
/// these rather than a string, which is what keeps "no caller-supplied file name" true even though
/// the two stores share one file implementation.
public enum SecretCredentialEntry: Sendable, Equatable, CaseIterable {
  /// The provider-keyed OAuth credential map.
  case llmCredentials
  /// The MCP server-keyed access-token map.
  case mcpCredentials

  public var name: String {
    switch self {
    case .llmCredentials:
      return SecretStatePaths.credentialEnvelopeName
    case .mcpCredentials:
      return SecretStatePaths.mcpCredentialEnvelopeName
    }
  }
}

/// The only production source of state-root-relative secret paths.
///
/// It takes a state root and nothing else. There is no member that turns a caller-supplied name
/// into a URL, so no store built on it — and no CLI flow driving one — can be pointed at a foreign
/// file such as another vendor's home directory or an exported auth blob. The absence of an import
/// path is a property of the type rather than a promise buried in control flow.
public struct SecretStatePaths: Sendable, Equatable {
  /// The 32-byte symmetric key protecting all three envelopes. Mode 0600, owner-only.
  public static let keyName = SecretFile.key
  /// The runtime secrets the daemon boots on: the Telegram token plus the optional LLM and search
  /// keys.
  public static let runtimeEnvelopeName = SecretFile.envelope
  /// The provider-keyed OAuth credential map, encrypted under the same key as the runtime envelope.
  /// Its associated data is distinct from that envelope's, so the two cannot be swapped: either one
  /// moved to the other's name fails authentication instead of opening as the wrong kind of secret.
  public static let credentialEnvelopeName = "llm-credentials.enc"
  /// The MCP server-keyed access-token map, sealed under the same key as the other two envelopes and
  /// kept apart by its own associated data: a token map moved to either other name fails
  /// authentication rather than opening as the wrong kind of secret.
  public static let mcpCredentialEnvelopeName = "mcp-credentials.enc"
  /// The daemon instance lock, named here so one type names every state-root entry the secret layer
  /// touches. `clawd run`, credential mutations, and `secrets seal` all acquire it, so a command
  /// that writes protected state cannot race the daemon or another writer.
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
  public var mcpCredentialEnvelope: URL {
    stateRoot.appendingPathComponent(Self.mcpCredentialEnvelopeName)
  }
  public var instanceLock: URL { stateRoot.appendingPathComponent(Self.instanceLockName) }

  public func url(for entry: SecretCredentialEntry) -> URL {
    switch entry {
    case .llmCredentials:
      return credentialEnvelope
    case .mcpCredentials:
      return mcpCredentialEnvelope
    }
  }

  /// The directory every entry above is renamed within — the fsync target that makes a rename
  /// durable, and the only directory publication ever opens.
  public var directory: URL { stateRoot }
}
