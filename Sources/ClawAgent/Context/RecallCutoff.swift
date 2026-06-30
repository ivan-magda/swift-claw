import ClawCore
import Foundation

public protocol RecallCutoff: Sendable {
  func select(hits: [RecallHit], limit: Int) -> [RecallHit]
}

public struct CandidateCapRecallCutoff: RecallCutoff {
  public init() {}

  public func select(hits: [RecallHit], limit: Int) -> [RecallHit] {
    guard limit > 0 else {
      return []
    }

    return Array(
      hits
        .filter { $0.score.value > 0 }
        .sorted { lhs, rhs in
          if lhs.score != rhs.score {
            return lhs.score > rhs.score
          }
          if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
          }
          return lhs.id < rhs.id
        }
        .prefix(limit)
    )
  }
}
