import Crypto
import Foundation

/// The per-run prompt/workspace fingerprint approvals bind to (spec §3.2). `policy_version` =
/// `combined(...)` = first 16 hex of SHA-256 over an order-pinned, length-prefixed concatenation of
/// the policy-relevant inputs at run start. Each part is length-prefixed so boundaries cannot be
/// confused ("ab"+"c" ≠ "a"+"bc"). Secret values are NEVER hashed — only surface/config identity.
/// A strict-inequality voider: any change to prompt files, tool surface, or egress config between
/// an approval's request and its resolution voids the approval with `stale_policy`.
public enum PolicyFingerprint {
  /// SHA-256 over length-prefixed parts (each part: 8-byte big-endian UInt64 UTF-8 byte count, then
  /// the UTF-8 bytes), rendered as the full 64-char lowercase hex digest.
  public static func hash(parts: [String]) -> String {
    var hasher = SHA256()

    for part in parts {
      let bytes = Array(part.utf8)
      withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { lengthBytes in
        hasher.update(data: Data(lengthBytes))
      }
      hasher.update(data: Data(bytes))
    }

    return hasher.finalize().map { byte in
      String(format: "%02x", byte)
    }.joined()
  }

  /// Input classes 2–3 (§3.2): the tool-registry surface (sorted by name — each tool contributes
  /// name, canonical `.sortedKeys` parameter JSON, `riskLevel.rawValue`, and the egress label),
  /// then the llm base URL, the search-endpoint presence, and the canonical workspace root. Computed
  /// once at the composition root and injected into `ContextBuilder`.
  public static func staticSubhash(
    tools: [ToolDefinition],
    llmBaseURL: String,
    searchEndpointPresent: Bool,
    workspaceRoot: String
  ) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    var parts: [String] = []
    for tool in tools.sorted(by: { lhs, rhs in lhs.name < rhs.name }) {
      // JSONValue encoding cannot realistically fail for the finite case set; tool name still
      // distinguishes entries. JSONEncoder output is always valid UTF-8, so the failable decode
      // preserves the byte-exact contribution and folds to "" only on the same encode failure.
      let canonicalParameters =
        (try? encoder.encode(tool.parameters))
        .flatMap { data in
          String(data: data, encoding: .utf8)
        } ?? ""
      parts.append(tool.name)
      parts.append(canonicalParameters)
      parts.append(tool.riskLevel.rawValue)
      parts.append(egressLabel(tool.egressClass))
    }
    parts.append(llmBaseURL)
    parts.append(searchEndpointPresent ? "search:present" : "search:absent")
    parts.append(workspaceRoot)

    return hash(parts: parts)
  }

  /// The combined fingerprint stored as `policy_version`: first 16 hex of the digest over the
  /// static sub-hash followed by the class-1 prompt materials in the pinned order
  /// [systemPrompt, soulText, agentsText, toolsText]. A missing/unreadable file folds in as "".
  public static func combined(staticSubhash: String, promptMaterials: [String]) -> String {
    String(hash(parts: [staticSubhash] + promptMaterials).prefix(16))
  }
}

// MARK: - Egress Label

private extension PolicyFingerprint {
  /// `ToolEgressClass` is not `String`-backed, so a stable label pins its contribution to the hash
  /// (a rename here voids every outstanding approval, which is the intended strictness).
  static func egressLabel(_ egressClass: ToolEgressClass) -> String {
    switch egressClass {
    case .none: "none"
    case .fixedEndpoint: "fixed_endpoint"
    case .arbitraryDestination: "arbitrary_destination"
    }
  }
}
