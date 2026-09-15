import Crypto
import Foundation

/// The per-run prompt and workspace fingerprint that binds an approval to its policy inputs.
///
/// `combined(...)` produces `policy_version`: the first 16 hexadecimal characters of SHA-256 over
/// the order-pinned, length-prefixed inputs at run start. Length prefixes distinguish input
/// boundaries; only surface and configuration identity is hashed, never secret values.
/// A changed fingerprint voids a pending approval with `stale_policy`.
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

  /// The credential-free configuration surface used by the static policy subhash.
  ///
  /// Includes the tool registry, LLM egress identity, search-endpoint presence, canonical workspace
  /// root, web-fetch SSRF exemptions, and execution configuration. Secret values are never
  /// included.
  public struct StaticInputs: Sendable {
    public let tools: [ToolDefinition]
    /// Where inference leaves for — a configured endpoint or a managed provider's fixed one — never
    /// a credential.
    ///
    /// Folded in so switching sinks (current ↔ managed, or one configured endpoint to another)
    /// voids a parked approval even when no base URL is configured at all.
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

  /// Hashes the tool and execution policy surfaces in a canonical order.
  ///
  /// Each tool contributes its name, canonical parameter JSON, metadata provenance, risk, fence
  /// label, egress label, and invocation identity. Tools are sorted by name; the remaining
  /// configuration includes normalized execution settings and sorted allowlists. Configuration
  /// order cannot move the hash, but a changed egress-policy input voids an outstanding approval.
  /// Composition computes this once and injects it into `ContextBuilder`.
  public static func staticSubhash(inputs: StaticInputs) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    var parts: [String] = []
    for tool in inputs.tools.sorted(by: {
      $0.name < $1.name
    }) {
      let canonicalParameters: String
      if let data = try? encoder.encode(tool.parameters) {
        canonicalParameters = String(data: data, encoding: .utf8) ?? ""
      } else {
        canonicalParameters = ""
      }

      parts.append(tool.name)
      parts.append(canonicalParameters)
      parts.append(tool.metadataProvenance.rawValue)
      parts.append(tool.riskLevel.rawValue)
      parts.append(tool.fenceLabel)
      parts.append(egressLabel(tool.egressClass))
      parts.append(tool.invocationIdentity ?? "")
      parts.append("requires_interactive_requester:\(tool.requiresInteractiveRequester)")
      parts.append("requires_group_approval:\(tool.requiresGroupApproval)")
    }

    parts.append(egressIdentityLabel(inputs.llmEgress))
    parts.append(inputs.searchEndpointPresent ? "search:present" : "search:absent")
    parts.append(inputs.workspaceRoot)

    let exemptLabel = inputs.webFetchExemptCIDRs.map(\.description).sorted().joined(separator: ",")
    parts.append("webfetch_exempt:" + exemptLabel)

    let exec = inputs.exec
    parts.append("exec.enabled:\(exec.enabled)")
    parts.append("exec.image:\(exec.image?.description ?? "absent")")
    parts.append("exec.registries:" + exec.imageRegistryAllowlist.sorted().joined(separator: ","))
    parts.append("exec.memory_mib:\(exec.memoryMiB)")
    parts.append("exec.cpus:\(exec.cpus)")
    parts.append("exec.timeout_s:\(exec.timeoutSeconds)")
    parts.append("exec.allow_egress:\(exec.allowEgress)")

    return hash(parts: parts)
  }

  /// Returns the 16-character policy fingerprint for the static hash and ordered prompt materials.
  ///
  /// Callers supply prompt materials in the pinned order: system prompt, proactive system prompt,
  /// soul, agents, tools. Missing or unreadable files contribute empty strings.
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
    case .none:
      "none"
    case .fixedEndpoint:
      "fixed_endpoint"
    case .arbitraryDestination:
      "arbitrary_destination"
    }
  }

  /// A stable, credential-free label for the LLM egress identity: the case, the provider id for a
  /// managed sink, and the endpoint (already canonical from route resolution).
  ///
  /// The current and managed cases carry distinct prefixes so no configured endpoint can ever
  /// collide with a managed one, which is what makes switching between them void an outstanding
  /// approval.
  static func egressIdentityLabel(_ egress: LLMEgressIdentity) -> String {
    switch egress {
    case .configuredEndpoint(let endpoint):
      return "llm_egress:configured:\(endpoint)"
    case .managed(let providerID, let endpoint):
      return "llm_egress:managed:\(providerID.rawValue):\(endpoint)"
    }
  }
}
