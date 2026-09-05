import Foundation
import Testing

@testable import ClawCore

/// One disallowed `Cc`/`Cf` scalar, paired with a human-readable name so a failure names the exact
/// code point rather than an opaque `Optional("\u{...}")`.
struct DisallowedScalarCase: Sendable, CustomTestStringConvertible {
  let name: String
  let scalar: Unicode.Scalar

  var testDescription: String { name }
}

@Suite struct LessonSetTests {
  @Test func canonicalNormalizesBeforeDigesting() throws {
    // given
    let raw = ["  Report only price changes.\r\n", "Report only price changes."]

    // when
    let error = #expect(throws: LessonSetError.self) {
      try LessonSet.canonical(jobId: 1, lessons: raw)
    }

    // then
    #expect(error == .duplicateLesson(index: 1))
  }

  @Test func digestIgnoresJobIdentity() throws {
    // given
    let lessons = ["Treat refreshed counters as noise."]

    // when
    let first = try LessonSet.canonical(jobId: 1, lessons: lessons)
    let second = try LessonSet.canonical(jobId: 2, lessons: lessons)

    // then
    #expect(first.digest == second.digest)
    #expect(first.jobId != second.jobId)
  }

  @Test func emptySetIsValidAndStable() {
    // given
    let first = LessonSet.empty(jobId: 1)

    // when
    let second = LessonSet.empty(jobId: 2)

    // then
    #expect(first.lessons.isEmpty)
    #expect(first.digest == second.digest)
  }

  @Test func capsCountUTF8BytesNotGraphemes() {
    // given — 300 graphemes, 600 UTF-8 bytes
    let cyrillic = String(repeating: "я", count: 300)

    // when
    let error = #expect(throws: LessonSetError.self) {
      try LessonSet.canonical(jobId: 1, lessons: [cyrillic])
    }

    // then
    #expect(error == .lessonTooLarge(index: 0, bytes: 600))
  }

  @Test func emptyLessonAfterTrimmingIsRejected() {
    // given — whitespace and newlines only, canonicalizes to the empty string
    let raw = ["   \n\t  "]

    // when
    let error = #expect(throws: LessonSetError.self) {
      try LessonSet.canonical(jobId: 1, lessons: raw)
    }

    // then
    #expect(error == .emptyLesson(index: 0))
  }

  @Test func aFourthLessonIsRejected() {
    // given
    let raw = ["One.", "Two.", "Three.", "Four."]

    // when
    let error = #expect(throws: LessonSetError.self) {
      try LessonSet.canonical(jobId: 1, lessons: raw)
    }

    // then
    #expect(error == .tooManyLessons(count: 4))
  }

  /// `maxSetBytes` (1536) equals `maxLessons` (3) times `maxLessonBytes` (512), so no combination of
  /// at most three lessons that each individually respect the per-lesson cap can ever total more
  /// than the set cap — a genuinely over-cap total is unreachable without first tripping
  /// `.tooManyLessons` or `.lessonTooLarge`. This proves the reachable form of the same bound: the
  /// total check uses an inclusive `<=`, so three lessons landing exactly on the combined cap are
  /// accepted rather than rejected by an off-by-one `<`.
  @Test func totalBytesExactlyAtTheCombinedCapIsAccepted() throws {
    // given — three distinct 512-byte lessons summing to exactly 1536 bytes
    let raw = (1...3).map { index in
      String(repeating: "a", count: 511) + String(index)
    }

    // when
    let set = try LessonSet.canonical(jobId: 1, lessons: raw)

    // then
    #expect(set.lessons.count == 3)
    #expect(set.lessons.reduce(0) { $0 + $1.utf8.count } == LessonSetLimits.maxSetBytes)
  }

  @Test(
    arguments: [
      DisallowedScalarCase(name: "right-to-left override U+202E", scalar: "\u{202E}"),
      DisallowedScalarCase(name: "zero-width space U+200B", scalar: "\u{200B}"),
      DisallowedScalarCase(name: "bell U+0007", scalar: "\u{0007}"),
      DisallowedScalarCase(name: "tab U+0009", scalar: "\u{0009}"),
    ]
  )
  func aControlOrFormatScalarIsRejected(_ testCase: DisallowedScalarCase) {
    // given — the scalar sits inside otherwise-valid text, not at the edges trimming would strip
    let raw = ["Before\(String(testCase.scalar))after."]

    // when
    let error = #expect(throws: LessonSetError.self) {
      try LessonSet.canonical(jobId: 1, lessons: raw)
    }

    // then
    #expect(error == .disallowedCharacter(index: 0, scalar: testCase.scalar))
  }

  @Test func anInteriorNewlineIsAccepted() throws {
    // given
    let raw = ["Line one.\nLine two."]

    // when
    let set = try LessonSet.canonical(jobId: 1, lessons: raw)

    // then
    #expect(set.lessons == raw)
  }

  @Test func swappingLessonOrderChangesTheDigest() throws {
    // given
    let forward = ["Report only price changes.", "Ignore refreshed counters."]
    let reversed = Array(forward.reversed())

    // when
    let first = try LessonSet.canonical(jobId: 1, lessons: forward)
    let second = try LessonSet.canonical(jobId: 1, lessons: reversed)

    // then
    #expect(first.digest != second.digest)
  }
}
