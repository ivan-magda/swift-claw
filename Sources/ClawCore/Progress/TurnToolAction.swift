/// A presentation category derived from registered identity, independent of display text.
public enum TurnToolAction: Sendable, Equatable {
  case tool
  case search
  case readPage
  case readFile
  case writeFile
  case memory
  case loadSkill
  case executeCode
  case coding

  public init(registeredName: String) {
    switch registeredName {
    case BuiltinToolNames.webSearch:
      self = .search
    case BuiltinToolNames.webFetch:
      self = .readPage
    case BuiltinToolNames.fileRead:
      self = .readFile
    case BuiltinToolNames.fileWrite:
      self = .writeFile
    case BuiltinToolNames.memoryWrite:
      self = .memory
    case BuiltinToolNames.skillLoad:
      self = .loadSkill
    case BuiltinToolNames.executeCode:
      self = .executeCode
    case CoderToolNames.submit:
      self = .coding
    default:
      self = .tool
    }
  }
}
