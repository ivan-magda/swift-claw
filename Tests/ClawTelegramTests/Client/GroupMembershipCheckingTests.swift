import ClawCore
import ClawTelegram
import ClawTestSupport
import Foundation
import Testing

@Suite struct GroupMembershipCheckingTests {
  struct MembershipCase: Sendable {
    let status: ChatMembershipStatus
    let presenceJSON: String
    let expected: Bool
  }

  @Test func lookupPostsTheRequestedChatAndUser() async throws {
    // given
    let http = ClawTestSupport.RecordingHTTPExecutor(
      cannedResult: Self.response(Self.memberJSON(status: .member))
    )
    let checker: any GroupMembershipChecking = TelegramClient(token: "T", http: http)

    // when
    _ = try await checker.isCurrentMember(chatId: -100_123, userId: 42)

    // then
    let request = try #require(await http.requests.first)
    #expect(request.method == .post)
    #expect(request.url == "https://api.telegram.org/botT/getChatMember")
    let data = try #require(request.body)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["chat_id"] as? Int64 == -100_123)
    #expect(body["user_id"] as? Int64 == 42)
  }

  @Test(arguments: [
    MembershipCase(status: .creator, presenceJSON: "", expected: true),
    MembershipCase(status: .administrator, presenceJSON: "", expected: true),
    MembershipCase(status: .member, presenceJSON: "", expected: true),
    MembershipCase(status: .restricted, presenceJSON: #", "is_member": true"#, expected: true),
    MembershipCase(status: .restricted, presenceJSON: #", "is_member": false"#, expected: false),
    MembershipCase(status: .restricted, presenceJSON: "", expected: false),
    MembershipCase(status: .left, presenceJSON: "", expected: false),
    MembershipCase(status: .kicked, presenceJSON: "", expected: false),
    MembershipCase(status: .other("future_member"), presenceJSON: "", expected: false),
  ])
  func currentMembershipRequiresRecognizedStatusAndPresence(
    _ testCase: MembershipCase
  ) async throws {
    // given
    let json = Self.memberJSON(status: testCase.status, presenceJSON: testCase.presenceJSON)
    let checker = makeClient(json: json)

    // when
    let isMember = try await checker.isCurrentMember(chatId: -100_123, userId: 42)

    // then
    #expect(isMember == testCase.expected)
  }

  @Test func anotherUsersMembershipDoesNotAuthorizeTheRequester() async throws {
    // given
    let checker = makeClient(json: Self.memberJSON(status: .member, userId: 99))

    // when
    let isMember = try await checker.isCurrentMember(chatId: -100_123, userId: 42)

    // then
    #expect(!isMember)
  }

  @Test(arguments: [
    #"{"status":"\#(ChatMembershipStatus.member.apiValue)"}"#,
    #"{"user":{"id":42,"is_bot":false,"first_name":"Ada"}}"#,
    memberJSON(status: .restricted, presenceJSON: #", "is_member": "true""#),
  ])
  func malformedMembershipCannotAuthorize(_ member: String) async {
    // given
    let checker = makeClient(json: member)

    // when / then
    await #expect {
      _ = try await checker.isCurrentMember(chatId: -100_123, userId: 42)
    } throws: { error in
      guard case TelegramError.decoding = error else {
        return false
      }
      return true
    }
  }

  @Test func transportWithoutMembershipSupportFailsClosed() async {
    // given
    let checker: any GroupMembershipChecking = DraftTransport()

    // when / then
    await #expect {
      _ = try await checker.isCurrentMember(chatId: -100_123, userId: 42)
    } throws: { error in
      guard case TelegramError.transport = error else {
        return false
      }
      return true
    }
  }
}

// MARK: - Fixtures

private extension GroupMembershipCheckingTests {
  static func memberJSON(
    status: ChatMembershipStatus,
    userId: Int64 = 42,
    presenceJSON: String = ""
  ) -> String {
    """
    {"status":"\(status.apiValue)",
     "user":{"id":\(userId),"is_bot":false,"first_name":"Ada"}\(presenceJSON)}
    """
  }

  static func response(_ member: String) -> HTTPResult {
    HTTPResult(
      statusCode: 200,
      headers: [:],
      body: Data(#"{"ok":true,"result":\#(member)}"#.utf8)
    )
  }

  func makeClient(json: String) -> TelegramClient {
    TelegramClient(
      token: "T",
      http: ClawTestSupport.RecordingHTTPExecutor(cannedResult: Self.response(json))
    )
  }
}
