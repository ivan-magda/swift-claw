import ClawCore
import ClawSecrets
import Foundation

/// Everything the boot path resolves for MCP before the first log line: the owner's server catalog,
/// its authentication outcomes, and the complete token-redaction set.
///
/// It is resolved that early because the tokens have to reach the redacting log backend before any
/// consumer exists that could write a line quoting one.
struct MCPBootInputs: Sendable {
  let config: MCPConfig
  /// One outcome per configured server, including the ones with nothing stored — "no token" and
  /// "a token minted for another URL" are both rows an owner needs to see.
  let credentials: [String: MCPCredentialLoad]
  /// Every token in the encrypted map, including orphaned and URL-mismatched records. These values
  /// are redaction-only and never authorize a request.
  let credentialRedactionValues: [String]

  /// No catalog: the feature is off, and every consumer downstream sees an empty tool set.
  static let empty = MCPBootInputs(
    config: .empty,
    credentials: [:],
    credentialRedactionValues: []
  )

  /// The process-wide redaction set: the secret store's values plus every MCP token this boot
  /// loaded. Built here so the log backend and every redactor read one list rather than each
  /// assembling their own — a consumer built from a narrower list is a token in a log file.
  func redactionValues(with secrets: Secrets) -> [String] {
    secrets.redactionValues + credentialRedactionValues
  }

  /// The token to authenticate `server` with, or nil when there is none to send. A token bound to a
  /// URL the server no longer points at reads as absent here, which is the whole point of the
  /// binding.
  func token(for server: String) -> String? {
    credentials[server]?.token
  }
}
