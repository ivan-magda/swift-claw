import Foundation
import Testing

@testable import ClawCore

@Suite struct PolicyFingerprintTests {
  // MARK: - hash(parts:)

  @Test func hashIsDeterministicAcrossCalls() {
    // given / when / then — same inputs, same digest (the recompute-at-resolution seam relies on it)
    let parts = ["alpha", "beta", "gamma"]
    #expect(PolicyFingerprint.hash(parts: parts) == PolicyFingerprint.hash(parts: parts))
  }

  @Test func hashRendersTheFullSHA256Hex() {
    // given / when / then — 32 digest bytes → 64 lowercase hex chars
    let digest = PolicyFingerprint.hash(parts: ["x"])
    #expect(digest.count == 64)
    #expect(digest.allSatisfy { character in "0123456789abcdef".contains(character) })
  }

  @Test func lengthPrefixDefeatsBoundaryConfusion() {
    // given / when / then — "ab"+"c" and "a"+"bc" share the byte stream, but the 8-byte length
    // prefixes differ, so the digests must differ (spec §3.2)
    #expect(
      PolicyFingerprint.hash(parts: ["ab", "c"]) != PolicyFingerprint.hash(parts: ["a", "bc"])
    )
  }

  @Test func emptyPartCountsAsAField() {
    // given / when / then — a present-but-empty file (missing → "") is distinct from an absent one
    #expect(PolicyFingerprint.hash(parts: ["", ""]) != PolicyFingerprint.hash(parts: [""]))
  }

  // MARK: - staticSubhash

  private func tool(
    name: String,
    params: JSONValue = .object(["type": .string("object")]),
    provenance: Provenance = .trusted,
    risk: RiskLevel = .safe,
    egress: ToolEgressClass = .none,
    fenceLabel: String? = nil,
    invocationIdentity: String? = nil
  ) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: "d",
      parameters: params,
      metadataProvenance: provenance,
      egressClass: egress,
      riskLevel: risk,
      fenceLabel: fenceLabel,
      invocationIdentity: invocationIdentity
    )
  }

  private func subhash(
    tools: [ToolDefinition] = [],
    egress: LLMEgressIdentity = .configuredEndpoint("https://llm.example"),
    search: Bool = false,
    root: String = "/workspace",
    exempt: [CIDR] = [],
    exec: ExecConfig = .disabledDefault
  ) -> String {
    PolicyFingerprint.staticSubhash(
      inputs: PolicyFingerprint.StaticInputs(
        tools: tools,
        llmEgress: egress,
        searchEndpointPresent: search,
        workspaceRoot: root,
        webFetchExemptCIDRs: exempt,
        exec: exec
      )
    )
  }

  @Test func staticSubhashIsIndependentOfToolInputOrder() {
    // given
    let first = tool(name: "a")
    let second = tool(name: "b")

    // when — sorted-by-name, so array order cannot move the hash
    let forward = subhash(tools: [first, second])
    let reversed = subhash(tools: [second, first])

    // then
    #expect(forward == reversed)
  }

  @Test func staticSubhashIsDeterministicForMultiKeySchemas() {
    // given — a multi-key parameter schema; `.sortedKeys` canonicalization makes the encoding
    // (and thus the hash) stable across calls
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object(["path": .string("string"), "content": .string("string")]),
    ])

    // when / then
    #expect(
      subhash(tools: [tool(name: "t", params: schema)])
        == subhash(tools: [tool(name: "t", params: schema)])
    )
  }

  @Test func toolNameIsAnInputClass() {
    // given / when / then — the sorted tool name is a hashed surface class (§3.2)
    #expect(subhash(tools: [tool(name: "a")]) != subhash(tools: [tool(name: "b")]))
  }

  @Test func toolParametersAreAnInputClass() {
    // given / when / then — the canonical parameter JSON is a hashed surface class (§3.2)
    #expect(
      subhash(tools: [tool(name: "t", params: .object(["type": .string("object")]))])
        != subhash(tools: [tool(name: "t", params: .object(["type": .string("string")]))])
    )
  }

  @Test func riskLevelIsAnInputClass() {
    // given / when / then — the declared riskLevel is a hashed surface class (§3.2)
    #expect(
      subhash(tools: [tool(name: "t", risk: .safe)])
        != subhash(tools: [tool(name: "t", risk: .ask)])
    )
  }

  @Test func metadataProvenanceIsAnInputClass() {
    // given / when / then
    #expect(
      subhash(tools: [tool(name: "t", provenance: .trusted)])
        != subhash(tools: [tool(name: "t", provenance: .untrusted)])
    )
  }

  @Test func fenceLabelIsAnInputClass() {
    // given / when / then — the declared fence label selects the prompt carve-out a tool's output
    // renders under, so changing it must void an outstanding approval the way a risk change does
    #expect(
      subhash(tools: [tool(name: "t", fenceLabel: nil)])
        != subhash(tools: [tool(name: "t", fenceLabel: "skills")])
    )
  }

  @Test func egressClassIsAnInputClass() {
    // given / when / then — the egress label is a hashed surface class (§3.2)
    #expect(
      subhash(tools: [tool(name: "t", egress: .none)])
        != subhash(tools: [tool(name: "t", egress: .arbitraryDestination)])
    )
  }

  @Test func invocationIdentityIsAnInputClass() {
    // given / when / then — two identically advertised MCP tools at different endpoints are
    // different actions, so an outstanding approval may not survive the endpoint change.
    #expect(
      subhash(tools: [tool(name: "mcp__docs__search", invocationIdentity: "https://a/mcp")])
        != subhash(
          tools: [tool(name: "mcp__docs__search", invocationIdentity: "https://b/mcp")]
        )
    )
  }

  @Test func llmEgressEndpointIsAnInputClass() {
    // given / when / then — the configured egress endpoint is a hashed config class
    #expect(
      subhash(egress: .configuredEndpoint("https://a"))
        != subhash(egress: .configuredEndpoint("https://b"))
    )
  }

  @Test func llmEgressDiffersBetweenCurrentAndManagedSinks() {
    // given — a configured endpoint and a managed provider whose fixed endpoint happens to be the
    // same string; the case prefix must still tell them apart so switching sinks voids an approval
    let sharedEndpoint = "https://chatgpt.com/backend-api/codex/responses"

    // when / then — the current and managed cases never collide, even on an identical endpoint
    #expect(
      subhash(egress: .configuredEndpoint(sharedEndpoint))
        != subhash(
          egress: .managed(providerID: .openAIChatGPT, endpoint: sharedEndpoint)
        )
    )
  }

  @Test func llmEgressManagedProviderIDIsAnInputClass() {
    // given / when / then — two managed sinks on the same endpoint but different providers hash apart
    #expect(
      subhash(egress: .managed(providerID: .openAIChatGPT, endpoint: "https://x"))
        != subhash(egress: .managed(providerID: .openAICompatible, endpoint: "https://x"))
    )
  }

  @Test func searchEndpointPresenceIsAnInputClass() {
    // given / when / then — the search-endpoint presence sentinel is a hashed config class (§3.2)
    #expect(subhash(search: true) != subhash(search: false))
  }

  @Test func workspaceRootIsAnInputClass() {
    // given / when / then — the canonical workspace root is a hashed config class (§3.2)
    #expect(subhash(root: "/a") != subhash(root: "/b"))
  }

  @Test func webFetchExemptCIDRsAreAnInputClass() throws {
    // given — the SSRF exemption list is egress policy; changing it must void an outstanding
    // web_fetch approval (else a pending action resolves under a policy that was not in force)
    let pool = try #require(CIDR.parse("198.18.0.0/15"))

    // when / then — presence changes the hash; absence is the strict default
    #expect(subhash(exempt: []) != subhash(exempt: [pool]))
  }

  @Test func webFetchExemptCIDRsAreOrderIndependent() throws {
    // given — config list order is arbitrary; two owners with the same set must share a policy
    let poolV4 = try #require(CIDR.parse("198.18.0.0/15"))
    let poolV6 = try #require(CIDR.parse("fc00::/18"))

    // when / then
    #expect(subhash(exempt: [poolV4, poolV6]) == subhash(exempt: [poolV6, poolV4]))
  }

  private func execConfig(
    enabled: Bool = false,
    imageCharacter: Character? = nil,
    registries: [String] = ["cgr.dev"],
    memoryMiB: Int = 1024,
    cpus: Int = 4,
    timeoutSeconds: Int = 30,
    allowEgress: Bool = false
  ) throws -> ExecConfig {
    let image = try imageCharacter.map { character in
      try #require(
        PinnedImageReference.parse(
          "cgr.dev/chainguard/python@sha256:" + String(repeating: character, count: 64)
        )
      )
    }
    return ExecConfig(
      enabled: enabled,
      image: image,
      imageRegistryAllowlist: registries,
      memoryMiB: memoryMiB,
      cpus: cpus,
      timeoutSeconds: timeoutSeconds,
      allowEgress: allowEgress
    )
  }

  @Test func everyExecPolicyFieldIsAnInputClass() throws {
    // given
    let baseline = try execConfig()
    let mutations = try [
      execConfig(enabled: true),
      execConfig(imageCharacter: "a"),
      execConfig(registries: ["cgr.dev", "images.example.com"]),
      execConfig(memoryMiB: 2048),
      execConfig(cpus: 2),
      execConfig(timeoutSeconds: 60),
      execConfig(allowEgress: true),
    ]

    // when
    let baselineHash = subhash(exec: baseline)
    let mutationHashes = mutations.map { config in subhash(exec: config) }

    // then: each field change produces a different policy fingerprint
    #expect(mutationHashes.allSatisfy { $0 != baselineHash })
    #expect(Set(mutationHashes).count == mutations.count)
  }

  @Test func execRegistryOrderDoesNotChangeTheFingerprint() throws {
    // given
    let forward = try execConfig(registries: ["cgr.dev", "images.example.com"])
    let reverse = try execConfig(registries: ["images.example.com", "cgr.dev"])

    // when / then: sorting makes equivalent registry sets produce the same fingerprint
    #expect(subhash(exec: forward) == subhash(exec: reverse))
  }

  // MARK: - combined

  @Test func combinedIsFirst16HexOfTheDigest() {
    // given / when
    let combined = PolicyFingerprint.combined(
      staticSubhash: "sub",
      promptMaterials: ["sys", "soul", "agents", "tools"]
    )

    // then — the persisted `policy_version` form (spec §3.2)
    #expect(combined.count == 16)
    #expect(
      combined
        == String(
          PolicyFingerprint.hash(parts: ["sub", "sys", "soul", "agents", "tools"]).prefix(16)
        )
    )
  }

  @Test func combinedIsSensitiveToTheStaticSubhash() {
    // given / when / then — a different classes 2–3 sub-hash flips the persisted fingerprint (§3.2)
    #expect(
      PolicyFingerprint.combined(staticSubhash: "s1", promptMaterials: ["a", "b", "c", "d"])
        != PolicyFingerprint.combined(staticSubhash: "s2", promptMaterials: ["a", "b", "c", "d"])
    )
  }

  @Test(arguments: 0..<4)
  func combinedIsSensitiveToEachPromptMaterial(_ index: Int) {
    // given
    var mutated = ["sys", "soul", "agents", "tools"]
    mutated[index] += "-changed"

    // when / then — a strict-inequality voider: any prompt-file edit flips the fingerprint (§3.2)
    #expect(
      PolicyFingerprint.combined(
        staticSubhash: "s",
        promptMaterials: ["sys", "soul", "agents", "tools"]
      )
        != PolicyFingerprint.combined(staticSubhash: "s", promptMaterials: mutated)
    )
  }
}
