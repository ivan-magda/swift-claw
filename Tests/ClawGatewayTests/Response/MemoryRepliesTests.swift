import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct MemoryRepliesTests {
  private func makeItem(
    id: Int64,
    text: String,
    kind: MemoryKind,
    sensitivity: Sensitivity = .normal,
    sessionId: Int64? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 86_400)
  ) -> MemoryItem {
    MemoryItem(
      id: id,
      text: text,
      kind: kind,
      sensitivity: sensitivity,
      importance: .normal,
      source: .owner,
      sessionId: sessionId,
      createdAt: createdAt
    )
  }

  @Test func reviewListGroupsByKindWithProvenanceLines() {
    // given
    let items = [
      makeItem(id: 12, text: "ship 3a", kind: .project),
      makeItem(id: 3, text: "prefers dark mode", kind: .user),
      makeItem(id: 1, text: "likes terse replies", kind: .user),
      makeItem(id: 7, text: "keep the owner posted", kind: .feedback),
      makeItem(id: 9, text: "cite sources", kind: .reference),
    ]

    // when
    let rendered = MemoryReplies.reviewList(items: items)

    // then
    let expected = """
      user:
      3 · «prefers dark mode» · owner · 1970-01-02
      1 · «likes terse replies» · owner · 1970-01-02
      feedback:
      7 · «keep the owner posted» · owner · 1970-01-02
      project:
      12 · «ship 3a» · owner · 1970-01-02
      reference:
      9 · «cite sources» · owner · 1970-01-02
      """
    #expect(rendered == expected)
  }

  @Test func reviewLineFlagsHighSensitivityAndTruncatesLongText() {
    // given
    let longText = String(repeating: "1234567890", count: 6) + "1"
    let item = makeItem(
      id: 5,
      text: longText,
      kind: .reference,
      sensitivity: .high
    )

    // when
    let rendered = MemoryReplies.reviewList(items: [item])

    // then
    let expectedSnippet = String(repeating: "1234567890", count: 6) + "…"
    #expect(
      rendered == """
        reference:
        5 · «\(expectedSnippet)» · owner · 1970-01-02 · ⚠
        """
    )
  }

  @Test func showItemRendersFullProvenanceAndText() {
    // given
    let item = makeItem(
      id: 9,
      text: "ship 3a",
      kind: .project,
      sessionId: 4
    )

    // when
    let rendered = MemoryReplies.showItem(item)

    // then
    #expect(
      rendered == """
        Memory 9: project
        source: owner · session: 4
        created: 1970-01-02 · sensitivity: normal

        ship 3a
        """
    )
  }

  @Test func showItemWithoutSessionSaysNone() {
    // given
    let item = makeItem(id: 2, text: "fact", kind: .user, sessionId: nil)

    // when
    let rendered = MemoryReplies.showItem(item)

    // then
    #expect(rendered.contains("session: none"))
  }

  @Test func deleteConfirmPromptShowsIdAndFullText() {
    // given
    let item = makeItem(id: 7, text: "obsolete fact", kind: .user)

    // when
    let prompt = MemoryReplies.deleteConfirmPrompt(item: item)

    // then
    #expect(prompt == "Delete memory 7?\n«obsolete fact»\nReply yes to delete, no to cancel.")
  }

  @Test func usageAndAckCopyAreExact() {
    // given / when / then
    #expect(
      MemoryReplies.rememberUsage == "Usage: /remember [user|feedback|project|reference:] <text>"
    )
    #expect(
      MemoryReplies.memoryUsage
        == "Usage: /memory [user|feedback|project|reference] | /memory show <id> | /memory delete <id>"
    )
    #expect(MemoryReplies.nothingToSave == "No savable text.")
    #expect(MemoryReplies.cancelled == "Cancelled.")
    #expect(
      MemoryReplies.saveFailed
        == "Couldn't save it. Nothing was written. Run /remember again."
    )
    #expect(
      MemoryReplies.deleteFailed
        == "Couldn't delete it. Nothing changed. Run /memory delete <id> again."
    )
    #expect(MemoryReplies.saved(id: 12) == "Saved memory 12.")
    #expect(MemoryReplies.saved(id: nil) == "Saved.")
    #expect(MemoryReplies.deleted(id: 12) == "Deleted memory 12.")
    #expect(MemoryReplies.notFound(id: 99) == "No memory with id 99.")
    #expect(MemoryReplies.emptyReview(kind: nil) == "No memories yet. Use /remember to save one.")
    #expect(MemoryReplies.emptyReview(kind: .project) == "No project memories yet.")
  }
}
