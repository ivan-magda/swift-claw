import ClawGateway
import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import clawd

@Suite struct ConferenceIntakeTests {
  @Test func configuredTopicReceivesHelpWhileOwnerDMIsIgnored() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "conference-intake")
    defer { try? FileManager.default.removeItem(at: root) }
    let chatID = ConferenceApprovedOriginFixture.chatID
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
      AppConfig.EnvKey.groupChats: String(chatID),
    ])
    let http = ScriptedHTTPExecutor([
      .ok(
        HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Data(
            #"{"ok":true,"result":{"message_id":900,"chat":{"id":-100123}}}"#.utf8
          )
        )
      )
    ])
    let builder = try CompositionAcceptance.makeBuilder(
      http: http,
      config: config,
      botIdentity: BotIdentity(id: 9, username: "ConferenceBot")
    )
    try builder.stores.allowlist.seedAllowlist(userIds: [101])
    let router = builder.makeIntakeRouter(
      coordination: DaemonBuilder.TurnCoordination(),
      turnRunner: IdleCompositionTurns(),
      imageCache: ImageCache(),
      scheduleSurface: ScheduleSurface(
        parser: IdleCompositionScheduleParser(),
        validator: ScheduleDraftValidator(minIntervalMinutes: 5, defaultTimezone: .gmt),
        calculator: OccurrenceCalculator(),
        jobs: builder.stores.scheduledJobs,
        commands: builder.stores.scheduleCommands
      ),
      approvalCallbacks: nil,
      doctor: IdleCompositionDoctor(),
      learning: nil,
      conferenceProfile: true
    )

    // when / then
    for kind in [ChatKind.private, .supergroup] {
      let outcome = await router.handle(
        rawUpdate: RawUpdate(
          updateId: kind == .private ? 1 : 2,
          message: RawMessage(
            messageId: 88,
            fromUserId: 101,
            chatId: kind == .private ? 101 : chatID,
            text: "/help",
            caption: nil,
            mediaKind: nil,
            chatKind: kind,
            chatTitle: nil,
            messageThreadId: kind == .private ? nil : ConferenceApprovedOriginFixture.threadID,
            senderDisplayName: nil
          ),
          editedMessage: nil
        )
      )
      #expect(outcome == (kind == .private ? .skipped : .processed))
    }
    let requests = await http.recorded
    #expect(requests.count == 1)
    let body = try #require(requests.first?.body)
    let json = try JSONDecoder().decode(JSONValue.self, from: body)
    #expect(json.objectValue?["chat_id"] == .integer(Int(chatID)))
    #expect(
      json.objectValue?["message_thread_id"]
        == .integer(Int(ConferenceApprovedOriginFixture.threadID))
    )
  }
}
