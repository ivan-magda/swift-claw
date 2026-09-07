import ClawCore
import Foundation

/// The model-facing wire shape is deliberately narrower than the recorded prepared request.
enum CoderSubmitArguments {
  static let fields: Set<String> = [
    "source",
    "task",
    "workspace",
    "start_ref",
    "deliverable",
    "base_branch",
    "instructions",
    "publish_existing_changes",
  ]

  static var schema: JSONValue {
    let optionalText: JSONValue = .object(["type": .array([.string("string"), .string("null")])])

    let sourceCases = [("local", "path"), ("githubRepository", "url"), ("githubIssue", "url")]
    let sources = sourceCases.map { name, field in
      objectSchema(
        properties: [
          name: objectSchema(
            properties: [field: .object(["type": .string("string")])],
            required: [field]
          )
        ],
        required: [name]
      )
    }

    return objectSchema(
      properties: [
        "source": .object(["oneOf": .array(sources)]),
        "task": .object([
          "type": .array([.string("string"), .string("null")]),
          "description": .string(
            """
            The requested repository change or outcome, with enough context for Codex to work
            without this chat. Preserve the user's scope, acceptance criteria and constraints.
            Required and nonblank for local and githubRepository sources; for githubIssue,
            omit or use null when the issue defines the work.
            """
          ),
        ]),
        "workspace": .object([
          "type": .string("string"),
          "enum": .array([
            .string(CoderWorkspaceMode.inPlace.rawValue),
            .string(CoderWorkspaceMode.separate.rawValue),
          ]),
        ]),
        "start_ref": optionalText,
        "deliverable": .object([
          "type": .string("string"),
          "enum": .array([
            .string(CoderDeliverable.localChanges.rawValue),
            .string(CoderDeliverable.pullRequest.rawValue),
          ]),
        ]),
        "base_branch": optionalText,
        "instructions": .object([
          "type": .array([.string("string"), .string("null")]),
          "description": .string(
            """
            Optional additional user requirements or preferences not already included in task.
            Omit or use null when there are none; do not move the task here or invent requirements.
            These supplement the task and do not change permissions, workspace or publication scope.
            """
          ),
        ]),
        "publish_existing_changes": .object(["type": .string("boolean"), "default": .bool(false)]),
      ],
      required: ["source", "workspace", "deliverable"]
    )
  }

  static func decode(_ value: JSONValue) throws -> CoderRequest {
    guard
      let object = value.objectValue, Set(object.keys).isSubset(of: fields),
      let sourceObject = object["source"]?.objectValue, sourceObject.count == 1,
      let sourceCase = sourceObject.first,
      let sourceFields = sourceCase.value.objectValue,
      let workspaceText = object["workspace"]?.stringValue,
      let workspace = CoderWorkspaceMode(rawValue: workspaceText),
      let deliverableText = object["deliverable"]?.stringValue,
      let deliverable = CoderDeliverable(rawValue: deliverableText)
    else {
      throw CoderError.invalidRequest("Use only the declared Coder fields and exactly one source.")
    }

    let source: CoderSource
    switch sourceCase.key {
    case "local":
      source = .local(path: try sourceText(sourceFields, field: "path"))
    case "githubRepository":
      source = .githubRepository(url: try sourceText(sourceFields, field: "url"))
    case "githubIssue":
      source = .githubIssue(url: try sourceText(sourceFields, field: "url"))
    default:
      throw CoderError.invalidRequest("Unknown Coder source.")
    }

    let publish: Bool
    switch object["publish_existing_changes"] {
    case nil:
      publish = false
    case .bool(let value):
      publish = value
    default:
      throw CoderError.invalidRequest("publish_existing_changes must be a boolean.")
    }

    return try CoderRequest(
      source: source,
      task: optionalText(object, field: "task"),
      workspace: workspace,
      startRef: optionalText(object, field: "start_ref"),
      deliverable: deliverable,
      baseBranch: optionalText(object, field: "base_branch"),
      instructions: optionalText(object, field: "instructions"),
      publishExistingChanges: publish
    )
    .validated()
  }
}

// MARK: - Wire Fields

private extension CoderSubmitArguments {
  static func sourceText(
    _ fields: [String: JSONValue],
    field: String
  ) throws -> String {
    guard
      Set(fields.keys) == [field],
      let value = fields[field]?.stringValue
    else {
      throw CoderError.invalidRequest("The source requires only its declared \(field) string.")
    }
    return value
  }

  static func optionalText(_ object: [String: JSONValue], field: String) throws -> String? {
    switch object[field] {
    case nil, .null:
      return nil
    case .string(let text):
      return text
    default:
      throw CoderError.invalidRequest("\(field) must be a string or null.")
    }
  }

  static func objectSchema(properties: [String: JSONValue], required: [String]) -> JSONValue {
    let requiredFields = required.map { field in
      JSONValue.string(field)
    }
    return .object([
      "type": .string("object"), "properties": .object(properties),
      "required": .array(requiredFields), "additionalProperties": .bool(false),
    ])
  }
}
