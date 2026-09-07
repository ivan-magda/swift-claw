import Foundation

actor CodexEvents {
  static let frameByteLimit = 1024 * 1024
  private var pending = Data()
  private(set) var completed = false
  private(set) var failed = false
  private(set) var invalid = false
  // swiftlint:disable:next discouraged_optional_collection
  private(set) var usage: [String: Int]?

  func consume(_ bytes: Data) throws {
    do {
      for fragment in bytes.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
        if fragment.offset > 0 {
          try frame()
          pending.removeAll(keepingCapacity: true)
        }
        guard pending.count + fragment.element.count <= Self.frameByteLimit else {
          throw CodexProtocolFailure.invalidEvents
        }
        pending.append(contentsOf: fragment.element)
      }
    } catch {
      invalid = true
      throw error
    }
  }

  func finish() throws {
    if !pending.isEmpty {
      do { try frame() } catch {
        invalid = true
        throw error
      }
      pending.removeAll()
    }
  }
}

// MARK: - Wire evidence

private extension CodexEvents {
  func frame() throws {
    guard !pending.isEmpty else {
      return
    }
    let event = try JSONDecoder().decode(Event.self, from: pending)
    switch event.type {
    case "turn.completed":
      completed = true
      usage = try JSONDecoder().decode(Completion.self, from: pending).usage ?? usage
    case "turn.failed", "error": failed = true
    default: break
    }
  }

  struct Event: Decodable {
    let type: String
  }

  struct Completion: Decodable {
    // swiftlint:disable:next discouraged_optional_collection
    let usage: [String: Int]?
  }
}
