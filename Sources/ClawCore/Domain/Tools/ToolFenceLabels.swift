import Foundation

/// Resolves the untrusted-fence label for a tool row by tool NAME, which is all either fence seam
/// has: the live loop labels an observation, and history replay labels a persisted row whose tool
/// instance is long gone. Built once from the dispatcher's declarations so both seams read the
/// same source of truth.
///
/// A name no registered tool claims resolves to `unattributed`, never to itself. Tool names are
/// model-supplied on the wire — an unknown one reaches the live seam as the dispatcher's
/// "Unknown tool …" observation — and a label is a trust statement the prompt's carve-outs are
/// written against, so only a registered tool's own declaration can earn one.
public struct ToolFenceLabels: Sendable, Equatable {
  /// The fence for a row no registered tool claims. It names no tool on purpose.
  public static let unattributed = "tool"

  /// No tool declares anything: every row fences as unattributed.
  public static let undeclared = ToolFenceLabels(definitions: [])

  private let labelsByToolName: [String: String]

  public init(definitions: [ToolDefinition]) {
    labelsByToolName = Dictionary(
      definitions.map { definition in
        (definition.name, definition.fenceLabel)
      },
      uniquingKeysWith: { first, _ in
        first
      }
    )
  }

  public func label(forToolNamed name: String) -> String {
    labelsByToolName[name] ?? Self.unattributed
  }
}
