import ClawCore
import Testing

@Suite
struct ProgressTextTests {
  @Test
  func splitSecretIsWithheldBeforePreviewTruncation() {
    // given
    let secret = "synthetic-token-value"
    let prefix = "synthetic-token"
    var redactor = StreamingSecretRedactor(secretValues: [secret])
    let padding = String(repeating: "x", count: TurnProgressLimits.explanationCharacters - 4)

    // when
    let first = redactor.append(padding + prefix)
    let second = redactor.append("-value trailing")
    let publishedFragments = [first, second, redactor.finish()]

    // then
    #expect(
      publishedFragments.allSatisfy {
        !$0.contains(secret)
      }
    )
    #expect(first.contains(prefix) == false)
    #expect(first == padding)
    #expect(second.contains(SecretRedactor.replacement))
    #expect(
      ProgressText.preview(
        publishedFragments.joined(),
        secretValues: [secret],
        limit: TurnProgressLimits.explanationCharacters
      ).count <= TurnProgressLimits.explanationCharacters
    )
  }

  @Test
  func unicodeCarryCompletionAndOverlappingSecretsAreSafe() {
    // given
    var redactor = StreamingSecretRedactor(secretValues: ["🔐秘密", "abc", "abcd"])

    // when
    let first = redactor.append("safe 🔐秘")
    let second = redactor.append("密 abc")
    let third = redactor.append("d ab")
    let final = redactor.finish()

    // then
    #expect(first == "safe ")
    #expect(second == SecretRedactor.replacement + " ")
    #expect(third == SecretRedactor.replacement + " ")
    #expect(final == "ab")
    #expect(redactor.finish().isEmpty)
  }

  @Test
  func normalizationCannotReconstructSecretBeforePreviewCap() {
    // given
    let cases = [
      ("synthetic-\u{202E}token", "synthetic-token"),
      ("synthetic\t\t token", "synthetic token"),
    ]

    // when
    let previews = cases.map { text, secret in
      ProgressText.preview(
        text,
        secretValues: [secret],
        limit: TurnProgressLimits.previewCharacters
      )
    }

    // then
    for preview in previews {
      #expect(preview == SecretRedactor.replacement)
    }
    #expect(
      ProgressText.preview(
        cases[0].0,
        secretValues: [cases[0].1],
        limit: 4
      ) == String(SecretRedactor.replacement.prefix(4))
    )
  }

  @Test
  func previewRedactsBeforeNormalizingAndCapsGraphemes() {
    // given
    let secret = "secret\nvalue"
    let unicode = "👨‍👩‍👧‍👦"

    // when
    let redacted = ProgressText.preview(
      " \(secret)\t\u{001B}\u{202E}< & [label](url) \(unicode)",
      secretValues: [secret],
      limit: 100
    )
    let capped = ProgressText.preview(unicode + unicode, secretValues: [], limit: 1)

    // then
    #expect(redacted == SecretRedactor.replacement + " < & [label](url) " + unicode)
    #expect(capped == unicode)
    #expect(ProgressText.preview("text", secretValues: [], limit: 0).isEmpty)
  }
}
