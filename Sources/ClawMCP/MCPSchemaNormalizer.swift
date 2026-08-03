import ClawCore

/// Repairs a remote tool's JSON Schema into the shape every provider encoder accepts.
///
/// `ToolDefinition.parameters` reaches the provider verbatim and the whole tool array travels in one
/// request, so a single server's sloppy schema does not fail that tool — it fails every conversation,
/// built-ins included. Hence four defensive repairs, each for a provider that rejects the raw form:
/// legacy `definitions` promoted to `$defs`, nullable `anyOf` unions collapsed to their real branch,
/// object-shaped nodes given the `type` they omitted, and `required` pruned to names that exist.
///
/// The pass is pure and position-aware: it recurses only into values that are schemas, so a property
/// literally named `definitions` keeps its name — rewriting a user-facing property into a meta
/// keyword is worse than the malformed schema it was meant to fix.
public enum MCPSchemaNormalizer {
  public static func normalize(_ schema: JSONValue) -> JSONValue {
    normalizeSchema(schema)
  }
}

// MARK: - Schema vocabulary

private extension MCPSchemaNormalizer {
  enum Keyword {
    static let anyOf = "anyOf"
    static let definitions = "definitions"
    static let defs = "$defs"
    static let properties = "properties"
    static let required = "required"
    static let type = "type"
    static let null = "null"
    static let object = "object"

    /// Values are maps of name → schema; the names are data and are never rewritten.
    static let schemaMaps = [properties, defs, definitions, "patternProperties"]
    /// Values are arrays of schemas.
    static let schemaArrays = [anyOf, "oneOf", "allOf", "prefixItems"]
    /// Values are a single schema, or (for `items`) a tuple of them. May legally be a bool.
    static let schemaValues = [
      "items", "additionalProperties", "not", "contains", "if", "then", "else",
    ]

    /// Keys whose presence means the node describes an object even when it forgot to say so.
    static let objectShaped = [properties, required, "additionalProperties"]
  }
}

// MARK: - Repairs

private extension MCPSchemaNormalizer {
  static func normalizeSchema(_ node: JSONValue) -> JSONValue {
    guard case .object(let raw) = node else {
      return node
    }

    // Collapse first: the surviving branch contributes the keys the later repairs read.
    var object = collapseNullableUnion(raw)
    object = promoteDefinitions(object)
    object = normalizeChildren(object)
    object = coerceObjectType(object)

    return .object(pruneRequired(object))
  }

  /// `anyOf: [X, {"type": "null"}]` is how a server spells "optional X"; some providers reject the
  /// union outright, so the real branch takes the node's place and its siblings (description, title)
  /// come along.
  static func collapseNullableUnion(_ object: [String: JSONValue]) -> [String: JSONValue] {
    guard case .array(let branches)? = object[Keyword.anyOf] else {
      return object
    }

    let nonNull = branches.filter {
      isNullType($0) == false
    }
    guard nonNull.count == 1, nonNull.count < branches.count,
      case .object(let branch) = nonNull[0]
    else {
      return object
    }

    var merged = branch
    for (key, value) in object where key != Keyword.anyOf && merged[key] == nil {
      merged[key] = value
    }

    return merged
  }

  static func isNullType(_ node: JSONValue) -> Bool {
    guard case .object(let object) = node else {
      return false
    }
    return object[Keyword.type]?.stringValue == Keyword.null
  }

  /// Only when `$defs` is absent: a schema carrying both spellings has already chosen the modern one,
  /// and silently dropping the legacy map would lose whatever `$ref`s still point at it.
  static func promoteDefinitions(_ object: [String: JSONValue]) -> [String: JSONValue] {
    guard let legacy = object[Keyword.definitions], object[Keyword.defs] == nil else {
      return object
    }

    var promoted = object
    promoted.removeValue(forKey: Keyword.definitions)
    promoted[Keyword.defs] = legacy

    return promoted
  }

  static func normalizeChildren(_ object: [String: JSONValue]) -> [String: JSONValue] {
    var result = object

    for key in Keyword.schemaMaps {
      guard case .object(let map)? = result[key] else {
        continue
      }
      result[key] = .object(
        map.mapValues { child in
          normalizeSchema(child)
        }
      )
    }

    for key in Keyword.schemaArrays {
      guard case .array(let branches)? = result[key] else {
        continue
      }
      result[key] = .array(normalizeAll(branches))
    }

    for key in Keyword.schemaValues {
      guard let value = result[key] else {
        continue
      }
      switch value {
      case .object:
        result[key] = normalizeSchema(value)
      case .array(let items):
        result[key] = .array(normalizeAll(items))
      default:
        continue
      }
    }

    return result
  }

  static func normalizeAll(_ nodes: [JSONValue]) -> [JSONValue] {
    nodes.map { node in
      normalizeSchema(node)
    }
  }

  static func coerceObjectType(_ object: [String: JSONValue]) -> [String: JSONValue] {
    let declared = object[Keyword.type]
    let stated = declared != nil && declared != .null
    let shaped = Keyword.objectShaped.contains {
      object[$0] != nil
    }
    guard stated == false, shaped else {
      return object
    }

    var coerced = object
    coerced[Keyword.type] = .string(Keyword.object)

    return coerced
  }

  /// A `required` entry with no matching property makes some providers reject the tool. Pruning to
  /// nothing drops the key: an empty list carries no meaning worth forwarding.
  static func pruneRequired(_ object: [String: JSONValue]) -> [String: JSONValue] {
    guard case .array(let entries)? = object[Keyword.required] else {
      return object
    }

    let properties = object[Keyword.properties]?.objectValue ?? [:]
    let kept = entries.filter { entry in
      guard let name = entry.stringValue else {
        return false
      }
      return properties[name] != nil
    }

    var pruned = object
    if kept.isEmpty {
      pruned.removeValue(forKey: Keyword.required)
    } else {
      pruned[Keyword.required] = .array(kept)
    }

    return pruned
  }
}
