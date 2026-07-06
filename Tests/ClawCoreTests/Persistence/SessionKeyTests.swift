import Foundation
import Testing

@testable import ClawCore

@Suite struct SessionKeyTests {
  @Test func syntheticFormsRenderAndNeverResolveAChatId() {
    // given / when / then — delivery targets live on the job row / in config, never in the key
    // (preamble Global Constraints); chatId(from:) must stay nil for both synthetic forms.
    #expect(SessionKey.scheduledJob(id: 7) == "sched:job:7")
    #expect(SessionKey.heartbeat == "sched:heartbeat")
    #expect(SessionKey.chatId(from: SessionKey.scheduledJob(id: 7)) == nil)
    #expect(SessionKey.chatId(from: SessionKey.heartbeat) == nil)
  }

  @Test func telegramDMKeysStillRoundTrip() {
    // given / when / then — the existing form is untouched
    #expect(SessionKey.telegramDM(chatId: 42) == "tg:dm:42")
    #expect(SessionKey.chatId(from: SessionKey.telegramDM(chatId: 42)) == 42)
  }
}
