import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent

@Suite struct ContextBuilderImageTests {
  private let pixel = ImagePart(
    data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
    mediaType: .jpeg,
    width: 1_280,
    height: 960
  )

  @Test func anUntrustedUserMessageWithAnImageRendersImageFirstThenTheFence() throws {
    // given — an inbound photo is untrusted by construction, so it lands on the fenced branch
    let stored = StoredMessage(
      role: .user,
      content: "Что это?",
      provenance: .untrusted,
      image: pixel
    )

    // when
    let rendered = try renderHistory([stored])

    // then — the image leads, and the caption keeps its untrusted fence
    let last = try #require(rendered.last)
    let parts = last.content.parts
    #expect(parts.count == 2)
    guard case .image(let image) = parts[0] else {
      Issue.record("expected the image part first")
      return
    }
    #expect(image == pixel)
    guard case .text(let text) = parts[1] else {
      Issue.record("expected a fenced text part second")
      return
    }
    #expect(text.contains("claw-untrusted"))
    #expect(text.contains("Что это?"))
  }

  @Test func aTrustedUserMessageWithAnImageKeepsTheImageAndTakesNoFence() throws {
    // given — only the fence is gated on provenance; the image must survive either tier, or a photo
    // dispatched as trusted would vanish with no error
    let stored = StoredMessage(
      role: .user,
      content: "look at this",
      provenance: .trusted,
      image: pixel
    )

    // when
    let rendered = try renderHistory([stored])

    // then
    let last = try #require(rendered.last)
    #expect(last.content.images == [pixel])
    #expect(last.content.text == "look at this")
  }

  @Test func anUntrustedUserMessageWithoutAnImageIsUnchanged() throws {
    // given — every existing untrusted message must render exactly as before
    let stored = StoredMessage(role: .user, content: "hi", provenance: .untrusted)

    // when
    let rendered = try renderHistory([stored])

    // then
    let last = try #require(rendered.last)
    #expect(last.content.isPlainText)
  }

  @Test func aPhotoRowWithNoCachedBytesSaysSoExplicitly() throws {
    // given — evicted by LRU pressure, dropped by the replay budget, or lost to a restart
    let stored = StoredMessage(
      role: .user,
      content: ImageMarkers.barePhoto,
      provenance: .untrusted,
      image: nil
    )

    // when
    let rendered = try renderHistory([stored])

    // then — silence here would recreate the original bug: the model answering about pixels it
    // cannot see while believing it can
    let message = try #require(rendered.last)
    #expect(message.content.images.isEmpty)
    #expect(message.content.text.contains(ImageMarkers.unavailable))
  }

  private func renderHistory(_ history: [StoredMessage]) throws -> [ChatMessage] {
    let builder = ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      workspace: EmptyWorkspace(),
      memoryStore: EmptyMemoryStore(),
      retriever: EmptyRetriever(),
      budget: .default
    )
    let snapshot = SessionContextSnapshot(
      history: history,
      historyMessageIds: Array(1...Int64(history.count)),
      windowStartMessageId: nil,
      isTainted: false,
      hasPrivateData: false
    )

    return try builder.assemble(snapshot: snapshot, sessionId: 1, origin: .interactive).messages
  }
}
