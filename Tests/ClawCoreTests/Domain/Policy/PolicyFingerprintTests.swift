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
    risk: RiskLevel = .safe,
    egress: ToolEgressClass = .none
  ) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: "d",
      parameters: params,
      egressClass: egress,
      riskLevel: risk
    )
  }

  private func subhash(
    tools: [ToolDefinition]? = nil,
    llm: String = "https://llm.example",
    search: Bool = false,
    root: String = "/workspace"
  ) -> String {
    PolicyFingerprint.staticSubhash(
      tools: tools ?? [tool(name: "file_read")],
      llmBaseURL: llm,
      searchEndpointPresent: search,
      workspaceRoot: root
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

  @Test func egressClassIsAnInputClass() {
    // given / when / then — the egress label is a hashed surface class (§3.2)
    #expect(
      subhash(tools: [tool(name: "t", egress: .none)])
        != subhash(tools: [tool(name: "t", egress: .arbitraryDestination)])
    )
  }

  @Test func llmBaseURLIsAnInputClass() {
    // given / when / then — the pinned llm base URL is a hashed config class (§3.2)
    #expect(subhash(llm: "https://a") != subhash(llm: "https://b"))
  }

  @Test func searchEndpointPresenceIsAnInputClass() {
    // given / when / then — the search-endpoint presence sentinel is a hashed config class (§3.2)
    #expect(subhash(search: true) != subhash(search: false))
  }

  @Test func workspaceRootIsAnInputClass() {
    // given / when / then — the canonical workspace root is a hashed config class (§3.2)
    #expect(subhash(root: "/a") != subhash(root: "/b"))
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
