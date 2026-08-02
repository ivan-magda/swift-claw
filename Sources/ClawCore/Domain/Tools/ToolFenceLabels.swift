import Foundation

/// Resolves the untrusted-fence label for a tool row by tool NAME, which is all either fence seam
/// has: the live loop labels an observation, and history replay labels a persisted row whose tool
/// instance is long gone. Built once from the dispatcher's declarations so both seams read the
/// same source of truth; an unknown name falls back to itself, so a tool that declares nothing
/// keeps fencing under its own name.
public struct ToolFenceLabels: Sendable, Equatable {
  private let labelsByToolName: [String: String]

  /// The identity resolver: every tool row fences under its own tool name.
  public static let toolNames = ToolFenceLabels(definitions: [])

  public init(definitions: [ToolDefinition]) {
    labelsByToolName = Dictionary(
      definitions.map { definition in (definition.name, definition.fenceLabel) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  public func label(forToolNamed name: String) -> String {
    labelsByToolName[name] ?? name
  }
}
