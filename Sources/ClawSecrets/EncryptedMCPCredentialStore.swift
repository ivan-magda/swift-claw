import ClawCore
import Crypto
import Foundation

// MARK: - Records

/// One server's access token together with the fingerprint of the URL it was issued for.
///
/// The URL is fingerprinted rather than stored: matching is all this binding ever needs, and a hash
/// keeps the owner's endpoints out of the plaintext a decrypted map would otherwise list beside
/// their tokens.
struct StoredMCPCredential: Codable, Equatable, Sendable {
  let token: String
  let urlFingerprint: String
}

/// What the store found for a configured server. The mismatch is its own answer rather than a bare
/// `nil`: "no token" and "a token issued for a different host" need different remedies, and only one
/// of them is fixed by running `clawd mcp set-token` again.
public enum MCPCredentialLoad: Sendable, Equatable {
  case absent
  case token(String)
  /// A token is stored, but for a URL this server no longer points at. It is treated as absent —
  /// a re-pointed server must never inherit the old host's credential.
  case boundToDifferentURL

  public var token: String? {
    guard case .token(let token) = self else {
      return nil
    }
    return token
  }
}

// MARK: - Store

/// The MCP server-keyed token map, sealed under the same 256-bit `secret.key` as the runtime and
/// provider envelopes and kept apart from them by its own purpose-labeled associated data.
///
/// Every token is stored with the fingerprint of the server URL it was set for. An owner who
/// re-points a server at another host gets `boundToDifferentURL` rather than a request that hands a
/// third party a credential minted for someone else.
public struct EncryptedMCPCredentialStore: Sendable {
  /// The version this store writes. Its AAD labels this file's purpose alongside this byte.
  static let envelopeVersion: UInt8 = 1
  /// Current version of the JSON map inside the envelope, moving independently of the envelope's.
  static let mapVersion = 1
  static let maximumEnvelopeByteCount = SealedCredentialFile<CredentialMap>.maximumEnvelopeByteCount

  static let envelopeCodec = AESGCMEnvelope(
    version: envelopeVersion,
    associatedData: associatedData(version: envelopeVersion)
  )

  static let envelopeReadPolicy = SealedCredentialFile<CredentialMap>.readPolicy

  private let file: SealedCredentialFile<CredentialMap>

  public init(stateRoot: URL) {
    self.init(stateRoot: stateRoot, publisher: SecureFilePublisher())
  }

  init(stateRoot: URL, publisher: SecureFilePublisher) {
    file = SealedCredentialFile(
      stateRoot: stateRoot,
      entry: .mcpCredentials,
      codec: Self.envelopeCodec,
      publisher: publisher
    )
  }

  // MARK: - Reading

  public func load(server: MCPServerConfig) throws(CredentialStoreError) -> MCPCredentialLoad {
    Self.outcome(for: try file.load()?.servers[server.name], server: server)
  }

  /// Every configured server's outcome in one read, so the boot path opens the envelope once rather
  /// than once per server — and so a server with nothing stored still gets a row to report.
  public func loadAll(
    servers: [MCPServerConfig]
  ) throws(CredentialStoreError) -> [String: MCPCredentialLoad] {
    let stored = try file.load()?.servers ?? [:]
    var outcomes: [String: MCPCredentialLoad] = [:]
    for server in servers {
      outcomes[server.name] = Self.outcome(for: stored[server.name], server: server)
    }
    return outcomes
  }

  /// The names carrying a record, whatever URL each was bound to. It is what lets an owner-facing
  /// listing name a token left behind by a server that is no longer configured.
  public func storedServerNames() throws(CredentialStoreError) -> [String] {
    guard let map = try file.load() else {
      return []
    }
    return map.servers.keys.sorted()
  }

  // MARK: - Writing

  /// Binds `token` to the server's current URL. A second call for the same name replaces the record,
  /// which is how a re-pointed server is repaired.
  public func save(token: String, for server: MCPServerConfig) throws(CredentialStoreError) {
    let record = StoredMCPCredential(
      token: token,
      urlFingerprint: Self.fingerprint(of: server.url)
    )
    try file.mutate { map in
      map.servers[server.name] = record
      return true
    }
  }

  /// Removes the record for `name`, reporting whether there was one. Takes a bare name rather than a
  /// config: a token outliving the server it belonged to is exactly what an owner clears.
  @discardableResult
  public func delete(server name: String) throws(CredentialStoreError) -> Bool {
    var removed = false
    try file.mutate { map in
      removed = map.servers.removeValue(forKey: name) != nil
      return removed
    }
    return removed
  }
}

// MARK: - URL Binding

extension EncryptedMCPCredentialStore {
  static func outcome(
    for record: StoredMCPCredential?,
    server: MCPServerConfig
  ) -> MCPCredentialLoad {
    guard let record else {
      return .absent
    }
    guard record.urlFingerprint == fingerprint(of: server.url) else {
      return .boundToDifferentURL
    }
    return .token(record.token)
  }

  /// SHA-256 over a canonical spelling of the URL: scheme and host lowercased (they are
  /// case-insensitive, so a re-typed config must not read as a different endpoint), everything else
  /// — port, path, query — left exactly as written, because all three choose which endpoint receives
  /// the token.
  static func fingerprint(of url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = url.scheme?.lowercased()
    components?.host = url.host?.lowercased()
    let canonical = components?.string ?? url.absoluteString
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

// MARK: - Plaintext Server Map

extension EncryptedMCPCredentialStore {
  /// The JSON inside the envelope, keyed by the owner's server name — the same name `mcp.yaml` and
  /// the CLI verbs speak, so nothing has to translate between a stored key and a configured one.
  struct CredentialMap: SealedCredentialMap {
    static let currentVersion = EncryptedMCPCredentialStore.mapVersion
    static let empty = CredentialMap()

    var version: Int
    var servers: [String: StoredMCPCredential]

    /// `version` has no default on the property itself: Codable synthesis would not honour one, and
    /// a map that reached disk without a version is one this build must refuse rather than assume.
    init(
      version: Int = EncryptedMCPCredentialStore.mapVersion,
      servers: [String: StoredMCPCredential] = [:]
    ) {
      self.version = version
      self.servers = servers
    }
  }

  static func decode(_ plaintext: Data) throws(CredentialStoreError) -> CredentialMap {
    try SealedCredentialFile<CredentialMap>.decode(plaintext)
  }
}

// MARK: - AES-GCM Envelope

extension EncryptedMCPCredentialStore {
  /// The AEAD associated data: this file's purpose and its version. It is the only thing separating
  /// this envelope from the provider map's under a shared key, so either file moved to the other's
  /// name fails its tag check instead of opening as the wrong kind of secret.
  static func associatedData(version: UInt8) -> Data {
    Data("swift-claw:mcp-credentials:v\(version)".utf8)
  }

  static func sealEnvelope(
    _ plaintext: Data,
    key: SymmetricKey
  ) throws(CredentialStoreError) -> Data {
    try envelopeCodec.sealCredential(plaintext, key: key)
  }

  static func openEnvelope(
    _ envelope: Data,
    key: SymmetricKey
  ) throws(CredentialStoreError) -> Data {
    try envelopeCodec.openCredential(envelope, key: key)
  }
}
