import ClawAuth
import ClawCore
import Foundation

/// Translates a provider-neutral `ChatRequest` into the Codex Responses request body.
///
/// It is a pure transformation that owns no transport and no credential: a request this route
/// cannot honor is refused here, where nothing has been sent yet and the refusal costs the owner
/// nothing. Headers belong to the wire adapter, and reasoning replay material to the adapter that
/// minted it — neither is this type's to know.
///
/// The Chat Completions encoder is deliberately not reused. The two routes agree on almost nothing
/// past the word "function": this one flattens tool definitions, splits an assistant turn into
/// separate message and call items, and carries system text outside the conversation entirely.
struct ChatGPTResponsesRequestEncoder: Sendable {
  /// The only reasoning material this route asks for. Summaries and commentary are not owner-visible
  /// output, so requesting them would buy text that is dropped on arrival.
  static let encryptedReasoningInclude = "reasoning.encrypted_content"

  func encode(request: ChatRequest) throws -> Data {
    // Dropping stop strings quietly would run the model against a contract the caller did not ask
    // for; the studied Codex route provides none to honor, so the request is refused whole.
    guard request.stop == nil else {
      throw ProviderError.terminal(
        status: nil,
        message: "the ChatGPT route has no stop-string contract to honor"
      )
    }

    let instructions = Self.instructions(from: request.messages)
    let tools = request.tools.map(Self.wireTool)

    guard let cacheKey = ChatGPTPromptCacheKey.make(instructions: instructions, tools: tools) else {
      throw Self.unencodableBody
    }

    let body = ChatGPTWireRequest(
      model: Self.unqualifiedModel(request.model),
      instructions: instructions,
      input: request.messages.flatMap(Self.inputItems),
      store: false,
      stream: true,
      include: [Self.encryptedReasoningInclude],
      promptCacheKey: cacheKey,
      tools: tools
    )

    guard let json = CanonicalJSON.encode(body) else {
      throw Self.unencodableBody
    }
    return Data(json.utf8)
  }
}

// MARK: - Request Mapping

private extension ChatGPTResponsesRequestEncoder {
  static let unencodableBody = ProviderError.terminal(
    status: nil,
    message: "the request could not be encoded for the ChatGPT route"
  )

  /// The route's prefix is how an owner selects it, not part of the model's name at the vendor.
  /// Stripping it here rather than trusting the caller keeps the qualified reference — which usage
  /// rows and diagnostics do carry, and which must stay distinct from it — from reaching the wire.
  static func unqualifiedModel(_ model: String) -> String {
    guard model.hasPrefix(ChatGPTProviderMetadata.modelPrefix) else {
      return model
    }
    return String(model.dropFirst(ChatGPTProviderMetadata.modelPrefix.count))
  }

  /// System text leaves the conversation and becomes the route's `instructions`, joined in the order
  /// it was written wherever it appears in the history.
  static func instructions(from messages: [ChatMessage]) -> String {
    messages
      .filter { message in
        message.role == .system
      }
      .map { message in
        message.content
      }
      .joined(separator: "\n\n")
  }

  static func inputItems(for message: ChatMessage) -> [ChatGPTWireInputItem] {
    switch message.role {
    case .system:
      // Already folded into `instructions`; sending it again would say it twice.
      return []
    case .user:
      return [.userText(message.content)]
    case .assistant:
      return assistantItems(for: message)
    case .tool:
      // A result that names no call has nothing the route can pair it with, and inventing an
      // identity for it would attach it to someone else's call.
      guard let callID = message.toolCallId else {
        return []
      }
      return [.functionCallOutput(callID: callID, output: message.content)]
    }
  }

  /// An assistant turn becomes its text and its calls as separate items, in that order. The calls
  /// are read from the proposal rather than from the text, so an adapter that later replaces that
  /// text with the reasoning material it replays cannot take the calls down with it. A turn that
  /// only proposed calls contributes no message item — there is no text to state.
  static func assistantItems(for message: ChatMessage) -> [ChatGPTWireInputItem] {
    var items: [ChatGPTWireInputItem] = []
    if message.content.isEmpty == false {
      items.append(.assistantText(message.content))
    }
    let calls = message.toolCalls.map { call in
      ChatGPTWireInputItem.functionCall(
        callID: call.id,
        name: call.name,
        arguments: call.argumentsJSON
      )
    }
    return items + calls
  }

  static func wireTool(_ definition: ToolDefinition) -> ChatGPTWireTool {
    ChatGPTWireTool(
      name: definition.name,
      description: definition.description,
      parameters: definition.parameters
    )
  }
}

// MARK: - Wire Types

/// The Responses body. Field order is not meaningful to the route, and the encoder that renders this
/// sorts keys anyway — which is what makes the body reproducible at all, since a tool's parameters
/// are a dictionary whose own iteration order is seeded per process.
struct ChatGPTWireRequest: Encodable {
  let model: String
  let instructions: String
  let input: [ChatGPTWireInputItem]
  let store: Bool
  let stream: Bool
  let include: [String]
  let promptCacheKey: String
  let tools: [ChatGPTWireTool]

  private enum CodingKeys: String, CodingKey {
    case model
    case instructions
    case input
    case store
    case stream
    case include
    case promptCacheKey = "prompt_cache_key"
    case tools
    case toolChoice = "tool_choice"
    case parallelToolCalls = "parallel_tool_calls"
  }

  /// The three tool fields are written together or not at all, in one branch rather than three:
  /// asking a route to choose a tool from a list it was never given is a request it can only refuse.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(instructions, forKey: .instructions)
    try container.encode(input, forKey: .input)
    try container.encode(store, forKey: .store)
    try container.encode(stream, forKey: .stream)
    try container.encode(include, forKey: .include)
    try container.encode(promptCacheKey, forKey: .promptCacheKey)

    guard tools.isEmpty == false else {
      return
    }
    try container.encode(tools, forKey: .tools)
    try container.encode("auto", forKey: .toolChoice)
    try container.encode(true, forKey: .parallelToolCalls)
  }
}

/// A tool as this route takes it: flat, with the name beside the type rather than nested under a
/// `function` object the way Chat Completions wants it.
struct ChatGPTWireTool: Encodable {
  let name: String
  let description: String
  let parameters: JSONValue

  private enum CodingKeys: String, CodingKey {
    case type
    case name
    case description
    case strict
    case parameters
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("function", forKey: .type)
    try container.encode(name, forKey: .name)
    try container.encode(description, forKey: .description)
    // Pinned rather than translated: a `ToolDefinition` carries no strictness, so there is no owner
    // intent to express here. Claiming strict adherence for schemas that were never written to it
    // would have the route reject calls the tools would have accepted.
    try container.encode(false, forKey: .strict)
    try container.encode(parameters, forKey: .parameters)
  }
}

/// One item of the conversation as the route reads it. A turn is not always one item: an assistant
/// message that proposed calls becomes a message item and a call item apiece.
enum ChatGPTWireInputItem: Encodable {
  case userText(String)
  case assistantText(String)
  case functionCall(callID: String, name: String, arguments: String)
  case functionCallOutput(callID: String, output: String)

  private enum CodingKeys: String, CodingKey {
    case type
    case role
    case status
    case content
    case callID = "call_id"
    case name
    case arguments
    case output
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .userText(let text):
      try container.encode("user", forKey: .role)
      try container.encode([ChatGPTWireContent(type: "input_text", text: text)], forKey: .content)
    case .assistantText(let text):
      try container.encode("assistant", forKey: .role)
      // Replayed history, never a turn in flight: the route is being told what was already said.
      try container.encode("completed", forKey: .status)
      try container.encode([ChatGPTWireContent(type: "output_text", text: text)], forKey: .content)
    case .functionCall(let callID, let name, let arguments):
      try container.encode("function_call", forKey: .type)
      try container.encode(callID, forKey: .callID)
      try container.encode(name, forKey: .name)
      try container.encode(arguments, forKey: .arguments)
    case .functionCallOutput(let callID, let output):
      try container.encode("function_call_output", forKey: .type)
      try container.encode(callID, forKey: .callID)
      try container.encode(output, forKey: .output)
    }
  }
}

struct ChatGPTWireContent: Encodable {
  let type: String
  let text: String
}
