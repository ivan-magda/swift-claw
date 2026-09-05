/// One tool call announced to the owner. `detail` is tool-authored — the exact command line a
/// host-execution tool is about to run — while `runId`/`chatId` say whose delivery sequence
/// carries the line.
public struct ToolInvocationEcho: Sendable, Equatable {
  public let runId: Int64
  public let chatId: Int64
  public let tool: String
  public let detail: String

  public init(runId: Int64, chatId: Int64, tool: String, detail: String) {
    self.runId = runId
    self.chatId = chatId
    self.tool = tool
    self.detail = detail
  }
}

/// Announces a tool call to the owner BEFORE its side effect starts, so a command that runs on the
/// host machine is read while it is still interruptible with `/stop`. Both execution paths a
/// dangerous tool has — the dispatcher's window-widened call and the approved-action executor's
/// resume — announce through this one seam.
///
/// Returns whether the announcement was durably accepted. A tool that declares an echo must not
/// execute when this seam reports failure.
public protocol ToolInvocationEchoing: Sendable {
  func echo(_ invocation: ToolInvocationEcho) async -> Bool
}
