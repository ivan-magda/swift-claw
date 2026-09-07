import Foundation

public enum LessonSetLimits {
  public static let maxLessons = 3
  public static let maxLessonBytes = 512
  public static let maxSetBytes = 1_536
}

public enum LessonSetError: Error, Sendable, Equatable {
  case emptyLesson(index: Int)
  case duplicateLesson(index: Int)
  case tooManyLessons(count: Int)
  case lessonTooLarge(index: Int, bytes: Int)
  case setTooLarge(bytes: Int)
  case disallowedCharacter(index: Int, scalar: Unicode.Scalar)
}

/// One immutable, bounded, job-scoped set of advisory rules. Identity is `(jobId, digest)`: the
/// digest covers content alone, so two jobs holding the same rules — the canonical empty set above
/// all — share a digest and differ only by owner.
public struct LessonSet: Sendable, Equatable {
  public let jobId: Int64
  public let schemaVersion: Int
  public let lessons: [String]
  public let digest: LessonSetDigest

  public var isEmpty: Bool {
    lessons.isEmpty
  }

  public static func empty(jobId: Int64) -> LessonSet {
    LessonSet(
      jobId: jobId,
      schemaVersion: schemaVersion,
      lessons: [],
      digest: digest(of: [])
    )
  }

  public static func canonical(
    jobId: Int64,
    lessons raw: [String]
  ) throws(LessonSetError) -> LessonSet {
    let normalized = try normalize(raw)
    return LessonSet(
      jobId: jobId,
      schemaVersion: schemaVersion,
      lessons: normalized,
      digest: digest(of: normalized)
    )
  }
}

// MARK: - Storage Form

package extension LessonSet {
  /// The exact bytes the digest is taken over, which is what `lesson_sets.canonical_bytes` holds:
  /// a stored set and its stored digest therefore cannot describe different content.
  var canonicalBytes: Data {
    let payload = DigestPayload(lessons: lessons, schemaVersion: schemaVersion)
    return (try? CanonicalJSON.data(encoding: payload)) ?? Data()
  }

  /// Rebuilds a stored set from its canonical bytes, re-running validation and re-deriving the
  /// digest. Returns nil when the bytes are not a lesson set this version can read.
  static func decoded(jobId: Int64, canonicalBytes: Data) -> LessonSet? {
    guard
      let payload = try? JSONDecoder().decode(DigestPayload.self, from: canonicalBytes),
      payload.schemaVersion == schemaVersion,
      let set = try? canonical(jobId: jobId, lessons: payload.lessons)
    else {
      return nil
    }
    return set
  }
}

// MARK: - Canonical Form

private extension LessonSet {
  static let schemaVersion = 1

  static func normalize(_ raw: [String]) throws(LessonSetError) -> [String] {
    guard raw.count <= LessonSetLimits.maxLessons else {
      throw .tooManyLessons(count: raw.count)
    }

    var seen: Set<String> = []
    var normalized: [String] = []
    var total = 0

    for (index, lesson) in raw.enumerated() {
      let canonical = canonicalText(lesson)
      guard canonical.isEmpty == false else {
        throw .emptyLesson(index: index)
      }
      if let offending = disallowedScalar(in: canonical) {
        throw .disallowedCharacter(index: index, scalar: offending)
      }
      let bytes = canonical.utf8.count
      guard bytes <= LessonSetLimits.maxLessonBytes else {
        throw .lessonTooLarge(index: index, bytes: bytes)
      }
      guard seen.insert(canonical).inserted else {
        throw .duplicateLesson(index: index)
      }
      total += bytes
      normalized.append(canonical)
    }

    guard total <= LessonSetLimits.maxSetBytes else {
      throw .setTooLarge(bytes: total)
    }
    return normalized
  }

  /// Unicode normalization, line-ending normalization, surrounding-whitespace removal — the exact
  /// order the accepted algorithm fixes, applied before any digest or cap decision.
  static func canonicalText(_ lesson: String) -> String {
    let unixLineEndings =
      lesson
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return unixLineEndings.precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Every Unicode general category `Cc` or `Cf` scalar except newline. This is the exact rule the
  /// validated reducer applies — an enumerated allowlist of format characters would accept bytes
  /// that reducer rejects, and tab is `Cc`, so it is rejected too. Defense in depth, not the
  /// security boundary: runtime policy stays authoritative for every model-proposed tool argument.
  static func disallowedScalar(in text: String) -> Unicode.Scalar? {
    text.unicodeScalars.first { scalar in
      guard scalar != "\n" else {
        return false
      }
      return scalar.properties.generalCategory == .control
        || scalar.properties.generalCategory == .format
    }
  }

  static func digest(of lessons: [String]) -> LessonSetDigest {
    let payload = DigestPayload(lessons: lessons, schemaVersion: schemaVersion)
    guard let bytes = try? CanonicalJSON.data(encoding: payload) else {
      return LessonSetDigest(rawValue: "")
    }
    return LessonSetDigest(rawValue: SHA256Digest.hex(bytes))
  }

  struct DigestPayload: Codable {
    let lessons: [String]
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
      case lessons
      case schemaVersion = "schema_version"
    }
  }
}
