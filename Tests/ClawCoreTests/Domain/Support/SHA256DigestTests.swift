import Foundation
import Testing

@testable import ClawCore

@Suite struct SHA256DigestTests {
  @Test func knownVectorsRenderLowercaseHex() {
    // given
    let empty = Data()
    let text = "abc"

    // when
    let emptyDigest = SHA256Digest.hex(empty)
    let textDigest = SHA256Digest.hex(text)

    // then
    #expect(emptyDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(textDigest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func approvalArgsHashUsesTheCanonicalRenderer() {
    // given
    let canonicalJSON = #"{"a":1,"b":2}"#

    // when
    let approvalHash = ApprovalArgsHash.sha256Hex(canonicalJSON)

    // then
    #expect(approvalHash == SHA256Digest.hex(canonicalJSON))
  }

  @Test func canonicalDigestValidationRejectsCaseLengthAndAlphabetMutants() {
    // given
    let valid = String(repeating: "a", count: 64)

    // when
    let validAccepted = SHA256Digest.isCanonicalHex(valid)
    let uppercaseAccepted = SHA256Digest.isCanonicalHex(valid.uppercased())
    let shortAccepted = SHA256Digest.isCanonicalHex(String(valid.dropLast()))
    let longAccepted = SHA256Digest.isCanonicalHex(valid + "a")
    let invalidAlphabetAccepted = SHA256Digest.isCanonicalHex(String(valid.dropLast()) + "g")

    // then
    #expect(validAccepted)
    #expect(uppercaseAccepted == false)
    #expect(shortAccepted == false)
    #expect(longAccepted == false)
    #expect(invalidAlphabetAccepted == false)
  }
}
