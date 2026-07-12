import ClawCore
import Foundation

enum RuntimeInitImageReference {
  // Host/port and repository grammar defer to the same authority that validates the pinned
  // workload image, so the two reference checks cannot drift apart; only tag grammar is local.
  static func isRegistryQualifiedTag(_ value: String) -> Bool {
    guard
      !value.isEmpty,
      !value.contains("://"),
      !value.contains("@"),
      !value.contains(where: \.isWhitespace),
      let slash = value.firstIndex(of: "/")
    else {
      return false
    }

    let hostWithPort = String(value[..<slash])
    let repositoryWithTag = String(value[value.index(after: slash)...])

    guard let colon = repositoryWithTag.lastIndex(of: ":") else {
      return false
    }

    let repository = String(repositoryWithTag[..<colon])
    let tag = String(repositoryWithTag[repositoryWithTag.index(after: colon)...])

    guard !repository.isEmpty, !tag.isEmpty else {
      return false
    }

    guard PinnedImageReference.isValidRegistryHost(hostWithPort) else {
      return false
    }

    let components = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard
      components.allSatisfy({ PinnedImageReference.isValidRepositoryComponent(String($0)) })
    else {
      return false
    }

    return tag.utf8.allSatisfy(isTagByte) && (tag.utf8.first.map(isTagStartByte) ?? false)
  }

  private static func isTagByte(_ byte: UInt8) -> Bool {
    isTagStartByte(byte) || byte == 0x2e || byte == 0x2d
  }

  private static func isTagStartByte(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5a)
      || (byte >= 0x61 && byte <= 0x7a)
      || (byte >= 0x30 && byte <= 0x39)
      || byte == 0x5f
  }
}
