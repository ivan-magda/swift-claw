import Foundation
import Testing

@testable import ClawCore

@Suite struct SHA256DigestTests {
  @Test func knownVectorsRenderLowercaseHex() {
    // given / when / then
    #expect(
      SHA256Digest.hex(Data())
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
      SHA256Digest.hex("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  @Test func approvalArgsHashUsesTheCanonicalRenderer() {
    // given
    let canonicalJSON = #"{"a":1,"b":2}"#

    // when / then
    #expect(ApprovalArgsHash.sha256Hex(canonicalJSON) == SHA256Digest.hex(canonicalJSON))
  }
}
