import Foundation
import Testing

@testable import ClawCore

@Suite struct ApprovalDomainTests {
  @Test func stateRawValuesMatchTheDBVocabulary() {
    // given / when / then — exactly four states, per ARCHITECTURE §7.1/§19.1
    #expect(ApprovalState.pending.rawValue == "PENDING")
    #expect(ApprovalState.approved.rawValue == "APPROVED")
    #expect(ApprovalState.rejected.rawValue == "REJECTED")
    #expect(ApprovalState.expired.rawValue == "EXPIRED")
  }

  @Test func decisionRawValuesMatchTheAuditVocabulary() {
    // given / when / then — the audit `decision` column vocabulary (spec §3.1, preamble D9)
    #expect(ApprovalDecision.rejected.rawValue == "rejected")
    #expect(ApprovalDecision.expired.rawValue == "expired")
    #expect(ApprovalDecision.cancelled.rawValue == "cancelled")
    #expect(ApprovalDecision.superseded.rawValue == "superseded")
    #expect(ApprovalDecision.stalePolicy.rawValue == "stale_policy")
  }

  @Test func nonceIsTwentyTwoURLSafeCharacters() {
    // given
    let urlSafeAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    // when
    let nonce = ApprovalNonce.generate()

    // then — 16 bytes → base64url unpadded is exactly 22 chars, ≤ Telegram's 64-byte cap
    // with the "apr:<nonce>:y" framing
    #expect(nonce.count == 22)
    #expect(nonce.allSatisfy { character in urlSafeAlphabet.contains(character) })
  }

  @Test func noncesDoNotRepeat() {
    // given / when — 128 bits of CSPRNG output cannot collide over a small sample
    let nonces = Set((0..<100).map { _ in ApprovalNonce.generate() })

    // then
    #expect(nonces.count == 100)
  }

  @Test func argsHashMatchesTheKnownSHA256Vectors() {
    // given / when / then — pins the digest algorithm + hex rendering the approve CAS
    // recomputes against (spec §6.2 step 5)
    #expect(
      ApprovalArgsHash.sha256Hex("")
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
      ApprovalArgsHash.sha256Hex("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }
}
