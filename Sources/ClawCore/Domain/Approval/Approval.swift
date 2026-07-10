import Crypto
import Foundation

/// Why a non-approve resolution happened — the audit `decision` column vocabulary.
/// Typed so no call site writes a magic decision string; the persisted column stays free-text
/// and carries these rawValues.
public enum ApprovalDecision: String, Sendable, Equatable {
  case rejected
  case expired
  case cancelled
  case superseded
  case stalePolicy = "stale_policy"
}

/// One `approvals` row.
public struct Approval: Sendable, Equatable {
  public let id: Int64
  public let runId: Int64
  public let sessionId: Int64
  public let state: ApprovalState
  public let tool: String
  public let canonicalArgsJSON: String
  public let canonicalTarget: String
  public let argsHash: String  // SHA-256 hex of canonicalArgsJSON
  public let policyVersion: String
  public let ownerUserId: Int64  // the run's delivery chat id
  public let nonce: String
  public let observationMessageId: Int64
  public let toolCallId: String
  public let reason: ApprovalReason
  public let promptMessageId: Int64?
  public let createdTs: Date
  public let expiresTs: Date
  public let resolvedTs: Date?

  public init(
    id: Int64,
    runId: Int64,
    sessionId: Int64,
    state: ApprovalState,
    tool: String,
    canonicalArgsJSON: String,
    canonicalTarget: String,
    argsHash: String,
    policyVersion: String,
    ownerUserId: Int64,
    nonce: String,
    observationMessageId: Int64,
    toolCallId: String,
    reason: ApprovalReason,
    promptMessageId: Int64?,
    createdTs: Date,
    expiresTs: Date,
    resolvedTs: Date?
  ) {
    self.id = id
    self.runId = runId
    self.sessionId = sessionId
    self.state = state
    self.tool = tool
    self.canonicalArgsJSON = canonicalArgsJSON
    self.canonicalTarget = canonicalTarget
    self.argsHash = argsHash
    self.policyVersion = policyVersion
    self.ownerUserId = ownerUserId
    self.nonce = nonce
    self.observationMessageId = observationMessageId
    self.toolCallId = toolCallId
    self.reason = reason
    self.promptMessageId = promptMessageId
    self.createdTs = createdTs
    self.expiresTs = expiresTs
    self.resolvedTs = resolvedTs
  }
}

/// The insert payload — id/state/prompt/resolved are store-owned (state always starts PENDING).
public struct NewApproval: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let tool: String
  public let canonicalArgsJSON: String
  public let canonicalTarget: String
  public let argsHash: String
  public let policyVersion: String
  public let ownerUserId: Int64
  public let nonce: String
  public let observationMessageId: Int64
  public let toolCallId: String
  public let reason: ApprovalReason
  public let createdTs: Date
  public let expiresTs: Date  // createdTs + approval_expiry

  public init(
    runId: Int64,
    sessionId: Int64,
    tool: String,
    canonicalArgsJSON: String,
    canonicalTarget: String,
    argsHash: String,
    policyVersion: String,
    ownerUserId: Int64,
    nonce: String,
    observationMessageId: Int64,
    toolCallId: String,
    reason: ApprovalReason,
    createdTs: Date,
    expiresTs: Date
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.tool = tool
    self.canonicalArgsJSON = canonicalArgsJSON
    self.canonicalTarget = canonicalTarget
    self.argsHash = argsHash
    self.policyVersion = policyVersion
    self.ownerUserId = ownerUserId
    self.nonce = nonce
    self.observationMessageId = observationMessageId
    self.toolCallId = toolCallId
    self.reason = reason
    self.createdTs = createdTs
    self.expiresTs = expiresTs
  }
}

/// 16 CSPRNG bytes, base64url without padding (22 chars). `SystemRandomNumberGenerator` is
/// CSPRNG-backed on Apple platforms and Linux, so no extra entropy dependency is needed.
public enum ApprovalNonce {
  public static func generate() -> String {
    var generator = SystemRandomNumberGenerator()
    var bytes = Data(capacity: 16)

    for _ in 0..<2 {
      withUnsafeBytes(of: generator.next()) { word in
        bytes.append(contentsOf: word)
      }
    }

    return bytes.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// The single canonical args digest: computed when an action is recorded and recomputed inside
/// the approve CAS. One helper so the two computations can never diverge.
public enum ApprovalArgsHash {
  public static func sha256Hex(_ canonicalArgsJSON: String) -> String {
    SHA256.hash(data: Data(canonicalArgsJSON.utf8))
      .map { byte in
        String(format: "%02x", byte)
      }
      .joined()
  }
}

/// Budget carry-over, derived from persisted rows: rounds and tool calls counted from the run's
/// messages, tokens/USD summed over provider_usage. Defined here so the `RunStore` seam can name
/// it; produced by `resumeUsage`.
public struct ResumeUsage: Sendable, Equatable {
  public let rounds: Int
  public let toolCalls: Int
  public let tokens: Int
  public let costUSD: Double

  public init(rounds: Int, toolCalls: Int, tokens: Int, costUSD: Double) {
    self.rounds = rounds
    self.toolCalls = toolCalls
    self.tokens = tokens
    self.costUSD = costUSD
  }
}
