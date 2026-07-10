import ClawCore
import Foundation

/// Durable-memory WRITE (spec §8.2, ask tier): the model proposes one `memory_items` row and the
/// owner approves via the durable fabric. The actual insert happens on the approval waiter in
/// ONE transaction with the observation update (`applyApprovedMemoryWrite`, exactly-once —
/// §6.3), so `execute` here is a fail-closed stub, never a write path. All argument decoding is
/// the shared `MemoryWriteArguments` (ClawCore), the same derivation the waiter rebuilds from
/// the recorded canonical args.
public struct MemoryWriteTool: Tool {
  /// §5.4: the preview stays owner-readable, never a wall of text.
  static let previewCapGraphemes = 400

  public init() {}

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "memory_write",
      description: """
        Save one durable memory item (owner approval required). kind is one of \
        user|feedback|project|reference; importance low|normal|high (default normal); \
        sensitivity normal|high (default normal).
        """,
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "text": .object([
            "type": .string("string"),
            "description": .string("The single fact to remember."),
          ]),
          "kind": .object([
            "type": .string("string"),
            "enum": .array([
              .string("user"), .string("feedback"), .string("project"), .string("reference"),
            ]),
          ]),
          "importance": .object([
            "type": .string("string"),
            "enum": .array([.string("low"), .string("normal"), .string("high")]),
          ]),
          "sensitivity": .object([
            "type": .string("string"),
            "enum": .array([.string("normal"), .string("high")]),
          ]),
        ]),
        "required": .array([.string("text"), .string("kind")]),
      ]),
      egressClass: .none,
      riskLevel: .ask
    )
  }

  public var timeout: Duration { .seconds(5) }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    switch MemoryWriteArguments.parse(arguments, sessionId: nil) {
    case .invalid(let reason):
      return .refused(reason: reason)
    case .parsed(let request):
      return .resolved(MemoryWriteArguments.canonicalTarget(for: request))
    }
  }

  public func approvalPresentation(
    arguments: JSONValue,
    canonicalTarget: String
  ) -> ToolApprovalPresentation {
    guard case .parsed(let request) = MemoryWriteArguments.parse(arguments, sessionId: nil)
    else {
      return ToolApprovalPresentation(
        blastRadius: "memory item",
        contentPreview: nil,
        warnings: []
      )
    }
    return ToolApprovalPresentation(
      blastRadius: """
        memory item, kind \(request.item.kind.rawValue), \
        sensitivity \(request.item.sensitivity.rawValue), \
        importance \(MemoryWriteArguments.importanceLabel(request.item.importance))
        """,
      // §8.2: the preview is the capped VERBATIM normalized text — the owner judges exactly
      // what would be stored; the scan warnings flag secret/instruction shapes, never hide them.
      contentPreview: ToolOutputCap.cap(
        request.item.text,
        maxGraphemes: Self.previewCapGraphemes
      ),
      warnings: request.warnings.map(\.confirmationSummary)
    )
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    // Ask-tier means the gate never allows a direct dispatch; the approved insert runs fused
    // with the observation update on the waiter (§6.3). Reaching this body is a wiring bug.
    ToolPayload(
      content: "memory_write executes only through the owner-approval resume path.",
      status: .error,
      ingestedUntrusted: false
    )
  }
}
