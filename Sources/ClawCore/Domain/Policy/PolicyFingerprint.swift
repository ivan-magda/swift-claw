import Crypto
import Foundation

/// The per-run prompt/workspace fingerprint approvals bind to. `policy_version` =
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

    return SHA256Digest.hex(digest: hasher.finalize())
  }

  /// The policy-relevant surface the static sub-hash is computed over: the tool-registry surface,
  /// the LLM egress identity, the search-endpoint presence, the canonical workspace root, the
  /// web_fetch SSRF exemption list, and the exec block. Secret values are never included.
  public struct StaticInputs: Sendable {
    public let tools: [ToolDefinition]
    /// Where inference leaves for — a configured endpoint or a managed provider's fixed one — never a
    /// credential. Folded in so switching sinks (current ↔ managed, or one configured endpoint to
    /// another) voids a parked approval even when no base URL is configured at all.
    public let llmEgress: LLMEgressIdentity
    public let searchEndpointPresent: Bool
    public let workspaceRoot: String
    public let webFetchExemptCIDRs: [CIDR]
    public let exec: ExecConfig

    public init(
      tools: [ToolDefinition],
      llmEgress: LLMEgressIdentity,
      searchEndpointPresent: Bool,
      workspaceRoot: String,
      webFetchExemptCIDRs: [CIDR],
      exec: ExecConfig
    ) {
      self.tools = tools
      self.llmEgress = llmEgress
      self.searchEndpointPresent = searchEndpointPresent
      self.workspaceRoot = workspaceRoot
      self.webFetchExemptCIDRs = webFetchExemptCIDRs
      self.exec = exec
    }
  }

  /// Hashes the static inputs: the tool surface sorted by name (each tool contributes name,
  /// canonical `.sortedKeys` parameter JSON, metadata provenance, `riskLevel.rawValue`, its fence
  /// label — a trust declaration on par with risk, since it selects the prompt carve-out its output
  /// renders under — the egress label, any declared invocation identity, and whether the tool needs
  /// an interactive run), then the remaining config identity with the exec block normalized
  /// (enabled state, pinned image, sorted registry
  /// allowlist, caps, timeout, and egress switch). Sorted lists mean config order cannot move the
  /// hash; a change to any egress-policy input voids an outstanding approval. Computed once at the
  /// composition root and injected into `ContextBuilder`.
  public static func staticSubhash(inputs: StaticInputs) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    var parts: [String] = []
    for tool in inputs.tools.sorted(by: { lhs, rhs in lhs.name < rhs.name }) {
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
      parts.append(tool.metadataProvenance.rawValue)
      parts.append(tool.riskLevel.rawValue)
      parts.append(tool.fenceLabel)
      parts.append(egressLabel(tool.egressClass))
      parts.append(tool.invocationIdentity ?? "")
      parts.append(tool.requiresInteractiveRun ? "interactive_only" : "any_origin")
    }
    parts.append(egressIdentityLabel(inputs.llmEgress))
    parts.append(inputs.searchEndpointPresent ? "search:present" : "search:absent")
    parts.append(inputs.workspaceRoot)
    let exemptLabel = inputs.webFetchExemptCIDRs.map(\.description).sorted().joined(separator: ",")
    parts.append("webfetch_exempt:" + exemptLabel)
    let exec = inputs.exec
    parts.append("exec.enabled:\(exec.enabled)")
    parts.append("exec.image:\(exec.image?.description ?? "absent")")
    parts.append(
      "exec.registries:" + exec.imageRegistryAllowlist.sorted().joined(separator: ",")
    )
    parts.append("exec.memory_mib:\(exec.memoryMiB)")
    parts.append("exec.cpus:\(exec.cpus)")
    parts.append("exec.timeout_s:\(exec.timeoutSeconds)")
    parts.append("exec.allow_egress:\(exec.allowEgress)")

    return hash(parts: parts)
  }

  /// The combined fingerprint stored as `policy_version`: first 16 hex of the digest over the
  /// static sub-hash followed by the prompt materials in the pinned order
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

  /// A stable, credential-free label for the LLM egress identity: the case, the provider id for a
  /// managed sink, and the endpoint (already canonical from route resolution). The current and
  /// managed cases carry distinct prefixes so no configured endpoint can ever collide with a managed
  /// one, which is what makes switching between them void an outstanding approval.
  static func egressIdentityLabel(_ egress: LLMEgressIdentity) -> String {
    switch egress {
    case .configuredEndpoint(let endpoint):
      return "llm_egress:configured:\(endpoint)"
    case .managed(let providerID, let endpoint):
      return "llm_egress:managed:\(providerID.rawValue):\(endpoint)"
    }
  }
}
