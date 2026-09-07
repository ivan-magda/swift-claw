import ClawCore
import Testing

@testable import ClawTools

@Suite struct CoderSubmitSchemaTests {
  @Test func advertisesStrictSourceAndPublicationScope() throws {
    // given
    let schema = CoderSubmitArguments.schema

    // when
    let properties = try strictProperties(schema, required: ["source", "workspace", "deliverable"])
    let source = try #require(properties["source"]?.objectValue)
    guard case .array(let alternatives) = source["oneOf"] else {
      Issue.record("Source has no alternatives")
      return
    }

    // then
    #expect(
      Set(properties.keys) == [
        "source", "task", "workspace", "start_ref", "deliverable", "base_branch",
        "instructions", "publish_existing_changes",
      ]
    )
    let expectedFields = ["local": "path", "githubRepository": "url", "githubIssue": "url"]
    var sourceNames: Set<String> = []
    for alternative in alternatives {
      let object = try #require(alternative.objectValue)
      let declared = try #require(object["properties"]?.objectValue)
      let name = try #require(declared.keys.first)
      #expect(declared.count == 1)
      sourceNames.insert(name)
      let associatedField = try #require(expectedFields[name])
      let fields = try strictProperties(alternative, required: [name])
      let nested = try strictProperties(try #require(fields[name]), required: [associatedField])
      #expect(Set(nested.keys) == [associatedField])
      #expect(nested[associatedField]?.objectValue?["type"] == .string("string"))
    }
    #expect(sourceNames == Set(expectedFields.keys))
    #expect(alternatives.count == sourceNames.count)
    for field in ["task", "start_ref", "base_branch", "instructions"] {
      #expect(try stringSet(properties[field]?.objectValue?["type"]) == ["string", "null"])
    }
    #expect(properties["workspace"]?.objectValue?["type"] == .string("string"))
    #expect(
      try stringSet(properties["workspace"]?.objectValue?["enum"]) == [
        CoderWorkspaceMode.inPlace.rawValue, CoderWorkspaceMode.separate.rawValue,
      ]
    )
    #expect(properties["deliverable"]?.objectValue?["type"] == .string("string"))
    #expect(
      try stringSet(properties["deliverable"]?.objectValue?["enum"]) == [
        CoderDeliverable.localChanges.rawValue, CoderDeliverable.pullRequest.rawValue,
      ]
    )
    let publication = try #require(properties["publish_existing_changes"]?.objectValue)
    #expect(publication["type"] == .string("boolean"))
    #expect(publication["default"] == .bool(false))
  }
}

// MARK: - Schema Assertions

private extension CoderSubmitSchemaTests {
  func strictProperties(_ schema: JSONValue, required: Set<String>) throws -> [String: JSONValue] {
    let object = try #require(schema.objectValue)
    #expect(object["type"] == .string("object"))
    #expect(object["additionalProperties"] == .bool(false))
    #expect(try stringSet(object["required"]) == required)
    return try #require(object["properties"]?.objectValue)
  }

  func stringSet(_ value: JSONValue?) throws -> Set<String> {
    let value = try #require(value)
    guard case .array(let elements) = value else {
      Issue.record("Expected an array of strings")
      return []
    }
    return try Set(
      elements.map { element in
        try #require(element.stringValue)
      }
    )
  }
}
