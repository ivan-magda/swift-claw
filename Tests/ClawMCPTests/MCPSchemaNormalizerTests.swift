import ClawCore
import Testing

@testable import ClawMCP

@Suite("MCP schema normalizer")
struct MCPSchemaNormalizerTests {
  @Test("a legacy definitions map is promoted to $defs")
  func promotesDefinitions() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "definitions": .object(["Issue": .object(["type": .string("string")])]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["definitions"] == nil)
    #expect(normalized["$defs"] == .object(["Issue": .object(["type": .string("string")])]))
  }

  @Test("references follow a promoted root definitions map")
  func rewritesRootDefinitionReferences() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "definitions": .object(["Issue": .object(["type": .string("string")])]),
      "properties": .object([
        "issue": .object(["$ref": .string("#/definitions/Issue")])
      ]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)
    let reference = normalized["properties"]?.objectValue?["issue"]?.objectValue?["$ref"]

    // then
    #expect(reference == .string("#/$defs/Issue"))
  }

  @Test("references follow a promoted nested definitions map with escaped pointer segments")
  func rewritesNestedDefinitionReferences() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object([
        "nested/name": .object([
          "definitions": .object(["Value": .object(["type": .string("string")])]),
          "properties": .object([
            "value": .object([
              "$ref": .string("#/properties/nested~1name/definitions/Value")
            ])
          ]),
        ])
      ]),
    ])

    // when
    let normalized = MCPSchemaNormalizer.normalize(schema)
    let nested = try #require(
      normalized.objectValue?["properties"]?.objectValue?["nested/name"]?.objectValue
    )
    let reference = nested["properties"]?.objectValue?["value"]?.objectValue?["$ref"]

    // then
    #expect(reference == .string("#/properties/nested~1name/$defs/Value"))
  }

  @Test("a property named definitions keeps its name")
  func leavesPropertyNamedDefinitionsAlone() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object(["definitions": .object(["type": .string("string")])]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)
    let properties = try #require(normalized["properties"]?.objectValue)

    // then
    #expect(properties["definitions"] == .object(["type": .string("string")]))
    #expect(properties["$defs"] == nil)
    #expect(normalized["$defs"] == nil)
  }

  @Test("a $defs map alongside the legacy spelling is left as it is")
  func keepsBothDefinitionSpellings() throws {
    // given
    let schema = JSONValue.object([
      "$defs": .object(["New": .object(["type": .string("string")])]),
      "definitions": .object(["Old": .object(["type": .string("string")])]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["$defs"]?.objectValue?["New"] != nil)
    #expect(normalized["definitions"]?.objectValue?["Old"] != nil)
  }

  @Test("a nullable anyOf union collapses to its non-null branch and keeps its siblings")
  func collapsesNullableUnion() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object([
        "cursor": .object([
          "description": .string("page cursor"),
          "anyOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("null")]),
          ]),
        ])
      ]),
    ])

    // when
    let normalized = MCPSchemaNormalizer.normalize(schema)
    let cursor = try #require(normalized.objectValue?["properties"]?.objectValue?["cursor"])

    // then
    #expect(
      cursor
        == .object([
          "type": .string("string"),
          "description": .string("page cursor"),
        ])
    )
  }

  @Test("a union without a null branch is left as it is")
  func keepsGenuineUnion() throws {
    // given
    let branches = JSONValue.array([
      .object(["type": .string("string")]),
      .object(["type": .string("number")]),
    ])
    let schema = JSONValue.object(["anyOf": branches])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["anyOf"] == branches)
  }

  @Test("an object-shaped node that omits its type is coerced to object")
  func coercesMissingType() throws {
    // given
    let schema = JSONValue.object([
      "properties": .object([
        "filter": .object(["properties": .object(["done": .object(["type": .string("boolean")])])])
      ])
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)
    let filter = try #require(normalized["properties"]?.objectValue?["filter"]?.objectValue)

    // then
    #expect(normalized["type"] == .string("object"))
    #expect(filter["type"] == .string("object"))
  }

  @Test("an explicit null type on an object-shaped node is replaced")
  func coercesNullType() throws {
    // given
    let schema = JSONValue.object([
      "type": .null,
      "properties": .object(["name": .object(["type": .string("string")])]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["type"] == .string("object"))
  }

  @Test("a node with no object markers keeps its missing type")
  func leavesUnshapedNodeAlone() throws {
    // given
    let schema = JSONValue.object(["description": .string("anything goes")])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["type"] == nil)
  }

  @Test("required is pruned to names that exist in properties")
  func prunesRequired() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object(["issueId": .object(["type": .string("string")])]),
      "required": .array([.string("issueId"), .string("ghost"), .number(7)]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["required"] == .array([.string("issueId")]))
  }

  @Test("a required list with nothing left is dropped")
  func dropsEmptyRequired() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object([:]),
      "required": .array([.string("ghost")]),
    ])

    // when
    let normalized = try #require(MCPSchemaNormalizer.normalize(schema).objectValue)

    // then
    #expect(normalized["required"] == nil)
    #expect(normalized["properties"] == .object([:]))
  }

  @Test("repairs reach nested schemas through items and $defs")
  func repairsNestedSchemas() throws {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object([
        "issues": .object([
          "type": .string("array"),
          "items": .object([
            "properties": .object(["id": .object(["type": .string("string")])]),
            "required": .array([.string("id"), .string("ghost")]),
          ]),
        ])
      ]),
    ])

    // when
    let normalized = MCPSchemaNormalizer.normalize(schema)
    let items = try #require(
      normalized.objectValue?["properties"]?.objectValue?["issues"]?.objectValue?["items"]?
        .objectValue
    )

    // then
    #expect(items["type"] == .string("object"))
    #expect(items["required"] == .array([.string("id")]))
  }

  @Test("an already-clean schema passes through unchanged")
  func passesCleanSchemaThrough() {
    // given
    let schema = JSONValue.object([
      "type": .string("object"),
      "properties": .object([
        "issueId": .object(["type": .string("string"), "description": .string("issue id")])
      ]),
      "required": .array([.string("issueId")]),
      "additionalProperties": .bool(false),
    ])

    // when
    let normalized = MCPSchemaNormalizer.normalize(schema)

    // then
    #expect(normalized == schema)
  }

  @Test(
    "a root that is not an object becomes an empty object schema",
    arguments: [
      JSONValue.string("not a schema"),
      JSONValue.null,
      JSONValue.array([]),
      JSONValue.bool(true),
    ]
  )
  func repairsNonObjectRoot(schema: JSONValue) {
    // given the server answered with something that is not a schema at all

    // when
    let normalized = MCPSchemaNormalizer.normalize(schema)

    // then the tool advertises no arguments rather than sending a body every provider rejects,
    // which would fail the whole request the built-in tools travel in too
    #expect(
      normalized == .object(["type": .string("object"), "properties": .object([:])])
    )
  }

  @Test("a non-object node inside a schema is left alone")
  func passesNonObjectChildThrough() {
    // given `additionalProperties: false` and an enum of scalars are both legal and not objects
    let schema = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "properties": .object([
        "mode": .object(["enum": .array([.string("fast"), .string("slow")])])
      ]),
    ])

    // when
    let normalized = MCPSchemaNormalizer.normalize(schema)

    // then
    #expect(normalized == schema)
  }

  @Test("a long remote description is cut with the canonical marker")
  func capsDescription() {
    // given
    let description = String(repeating: "d", count: MCPDescriptionCap.maxGraphemes + 500)

    // when
    let capped = MCPDescriptionCap.cap(description)

    // then
    #expect(capped.count == MCPDescriptionCap.maxGraphemes)
    #expect(capped.hasSuffix(TextTruncation.marker))
  }

  @Test("a description inside the cap is left alone")
  func keepsShortDescription() {
    // given
    let description = "Lists issues in the workspace."

    // when
    let capped = MCPDescriptionCap.cap(description)

    // then
    #expect(capped == description)
  }
}
