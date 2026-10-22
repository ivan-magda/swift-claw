import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite
struct LabeledContextFactoryTests {
  @Test
  func factoryGeneratesFreshNonceForEachWrapper() throws {
    // given
    let first = LabeledContextFactory.make(label: "memory_items", content: "same")
    let second = LabeledContextFactory.make(label: "memory_items", content: "same")

    // then
    #expect(first.label == "memory_items")
    #expect(first.content == "same")
    #expect(first.nonce.isEmpty == false)
    #expect(second.nonce.isEmpty == false)
    #expect(first.nonce != second.nonce)
  }
}
