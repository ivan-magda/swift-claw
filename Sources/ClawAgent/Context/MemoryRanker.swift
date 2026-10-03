import ClawCore
import Foundation

enum MemoryRanker {
  static func rank(items: [MemoryItem], excludeSensitive: Bool, cap: Int) -> [MemoryItem] {
    guard cap > 0 else {
      return []
    }

    let rankedItems =
      items
      .filter { item in
        !excludeSensitive || item.sensitivity != .high
      }
      .sorted { lhs, rhs in
        if lhs.importance != rhs.importance {
          return lhs.importance > rhs.importance
        }

        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt > rhs.createdAt
        }

        return lhs.id > rhs.id
      }

    var remaining = cap
    var selected = [MemoryItem]()

    for item in rankedItems {
      guard item.text.count <= remaining else {
        continue
      }

      selected.append(item)
      remaining -= item.text.count
    }

    return selected
  }
}
