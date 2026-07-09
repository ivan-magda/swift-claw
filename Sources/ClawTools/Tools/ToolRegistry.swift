import ClawCore
import Foundation

/// The v1 tool catalog: name → impl, plus the ordered wire `tools` array. Composition decides
/// membership (an unkeyed `web_search` is simply never constructed — unconfigured ⇒ absent, §7.3).
public struct ToolRegistry: Sendable {
  private let orderedTools: [any Tool]
  /// `public`: Task 16's composition root builds `ApprovedActionExecutor`'s name-keyed tool table
  /// from this same catalog, so the approve-resume path executes the identical tool instances the
  /// gated dispatcher does.
  public let toolsByName: [String: any Tool]

  public init(tools: [any Tool]) {
    orderedTools = tools
    toolsByName = Dictionary(
      uniqueKeysWithValues: tools.map { tool in
        (tool.definition.name, tool)
      }
    )
  }

  public var definitions: [ToolDefinition] {
    orderedTools.map(\.definition)
  }

  public func tool(named name: String) -> (any Tool)? {
    toolsByName[name]
  }
}
