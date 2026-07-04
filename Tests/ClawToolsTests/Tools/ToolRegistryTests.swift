import ClawCore
import Foundation
import Testing

@testable import ClawTools

/// A scripted tool for registry/dispatcher tests.
struct StubTool: Tool {
  let definition: ToolDefinition
  let timeout: Duration
  let payload: ToolPayload

  init(
    name: String,
    timeout: Duration = .seconds(1),
    payload: ToolPayload = ToolPayload(content: "ok", status: .ok, ingestedUntrusted: false)
  ) {
    definition = ToolDefinition(
      name: name,
      description: "stub",
      parameters: .object(["type": .string("object")])
    )
    self.timeout = timeout
    self.payload = payload
  }

  func execute(arguments: JSONValue) async -> ToolPayload {
    payload
  }
}

@Suite struct ToolRegistryTests {
  @Test func definitionsPreserveConstructionOrder() {
    // given
    let registry = ToolRegistry(tools: [StubTool(name: "web_search"), StubTool(name: "file_read")])

    // when / then
    #expect(registry.definitions.map(\.name) == ["web_search", "file_read"])
  }

  @Test func lookupResolvesByNameAndMissesUnknown() {
    // given
    let registry = ToolRegistry(tools: [StubTool(name: "file_read")])

    // when / then
    #expect(registry.tool(named: "file_read")?.definition.name == "file_read")
    #expect(registry.tool(named: "shell_exec") == nil)
  }
}
