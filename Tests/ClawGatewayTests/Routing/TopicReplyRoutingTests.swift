import ClawCore
import Foundation
import Testing

@testable import ClawGateway

/// A room is many conversations at once. Every reply the router sends itself — an ack, a canned
/// answer, a refusal — has to land in the topic that asked and under the message that asked, or an
/// attendee reads an answer to somebody else's question.
@Suite struct TopicReplyRoutingTests {
  private static let groupChatId: Int64 = -1_001
  private static let topicId: Int64 = 5

  private func makeHarness() throws -> MemoryRoutingHarness {
    try MemoryRoutingHarness.make(groupChats: [Self.groupChatId])
  }

  private func groupUpdate(id: Int64, text: String) -> RawUpdate {
    textUpdate(
      id: id,
      from: 7,
      chat: Self.groupChatId,
      text: text,
      chatKind: .supergroup,
      messageThreadId: Self.topicId,
      senderDisplayName: "Ada"
    )
  }

  @Test func aCannedReplyLandsInTheCallingTopicAsAReply() async throws {
    // given
    let harness = try makeHarness()

    // when — a command whose whole effect is a canned answer
    let outcome = await harness.router.handle(rawUpdate: groupUpdate(id: 11, text: "/help"))

    // then
    #expect(outcome == .processed)
    let sent = try #require(await harness.transport.sent.first)
    #expect(sent.text == CommandReplies.help(mode: .group))
    #expect(sent.text.contains("/learning") == false)
    #expect(sent.text.contains("learning state live in my owner's direct chat"))
    #expect(
      sent.target
        == DeliveryTarget(
          chatId: Self.groupChatId,
          messageThreadId: Self.topicId,
          replyToMessageId: 11
        )
    )
  }

  @Test func aRefusalLandsInTheCallingTopicAsAReply() async throws {
    // given
    let harness = try makeHarness()

    // when — an owner-scoped command the room may not run
    await harness.router.handle(rawUpdate: groupUpdate(id: 12, text: "/memory"))

    // then
    let sent = try #require(await harness.transport.sent.first)
    #expect(sent.text == CommandReplies.directOnly)
    #expect(sent.target.messageThreadId == Self.topicId)
    #expect(sent.target.replyToMessageId == 12)
  }

  /// The General topic carries no thread id, so its answers can only be threaded under the asking
  /// message — a fabricated thread id would address a topic that does not exist.
  @Test func aGeneralTopicReplyCarriesNoThread() async throws {
    // given
    let harness = try makeHarness()
    let update = textUpdate(
      id: 13,
      from: 7,
      chat: Self.groupChatId,
      text: "/help",
      chatKind: .supergroup,
      senderDisplayName: "Ada"
    )

    // when
    await harness.router.handle(rawUpdate: update)

    // then
    let sent = try #require(await harness.transport.sent.first)
    #expect(sent.target == DeliveryTarget(chatId: Self.groupChatId, replyToMessageId: 13))
  }

  @Test func aDirectReplyCarriesNeitherTopicNorReply() async throws {
    // given
    let harness = try makeHarness()

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 14, from: 42, text: "/help"))

    // then — the DM send is the whole-chat target it was before topics existed
    let sent = try #require(await harness.transport.sent.first)
    #expect(sent.target == .chat(42))
  }
}
