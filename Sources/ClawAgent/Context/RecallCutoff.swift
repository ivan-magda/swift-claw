import ClawCore
import Foundation

public protocol RecallCutoff: Sendable {
  func select(_ hits: [RecallHit], limit: Int) -> [RecallHit]
}

public struct CandidateCapRecallCutoff: RecallCutoff {
  public init() {}

  public func select(_ hits: [RecallHit], limit: Int) -> [RecallHit] {
    guard limit > 0 else { return [] }

    return Array(
      hits
        .filter { hit in hit.score.value > 0 }
        .sorted { first, second in
          if first.score != second.score {
            return first.score > second.score
          }
          if first.createdAt != second.createdAt {
            return first.createdAt > second.createdAt
          }
          return first.id < second.id
        }
        .prefix(limit)
    )
  }
}
