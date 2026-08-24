import ClawCore
import Foundation
import Logging

/// The deterministic, gateway-authored line that precedes a host command. Everything the owner
/// reads is authored HERE: the model supplies only the command text, which arrives already
/// canonicalized and scanned, and is redacted and capped again before it is shown.
///
/// One durable outbox chunk per command, enqueued and poked before the command starts, so the
/// owner can read it and answer with `/stop` while it is still running.
public struct OutboxInvocationEcho: ToolInvocationEchoing {
  private let outbox: any OutboxStore
  private let redactor: SecretRedactor
  /// Pokes the outbox dispatcher to drain. Without it the line would wait for the turn commit —
  /// which is exactly the moment the echo exists to come before.
  private let notifyOutbox: @Sendable () -> Void
  private let logger: Logger

  public init(
    outbox: any OutboxStore,
    redactor: SecretRedactor,
    notifyOutbox: @escaping @Sendable () -> Void,
    logger: Logger
  ) {
    self.outbox = outbox
    self.redactor = redactor
    self.notifyOutbox = notifyOutbox
    self.logger = logger
  }

  public func echo(_ invocation: ToolInvocationEcho) async -> Bool {
    let text = Self.text(for: invocation, redactor: redactor)
    do {
      guard
        try outbox.enqueueNotice(
          runId: invocation.runId,
          chatId: invocation.chatId,
          text: text
        )
      else {
        logger.error("could not enqueue the \(invocation.tool) echo for run \(invocation.runId)")
        return false
      }
    } catch {
      logger.error(
        "could not enqueue the \(invocation.tool) echo for run \(invocation.runId): \(error)"
      )
      return false
    }
    notifyOutbox()
    return true
  }

  /// The owner-visible line: a fixed headline naming the tool and the interrupt, then the command
  /// in a fence. Bounded by the same preview cap an approval prompt uses — the owner is reading to
  /// recognize the command, not to audit a long script.
  static func text(for invocation: ToolInvocationEcho, redactor: SecretRedactor) -> String {
    let detail = ToolOutputCap.cap(
      OwnerDisplaySanitizer.renderUnsafeScalars(in: redactor.redact(invocation.detail)),
      maxGraphemes: ToolOutputCap.approvalPreviewGraphemes
    )
    return """
      ⏵ Running \(invocation.tool) now — /stop to interrupt.
      ```
      \(detail)
      ```
      """
  }
}
