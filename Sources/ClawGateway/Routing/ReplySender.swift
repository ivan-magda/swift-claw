import ClawCore
import Foundation
import Logging

/// A routing decision that is already final — the failure was mapped, any notice sent — thrown so
/// handlers unwind straight to `MessageRouter.handle`, the single place the outcome is returned
/// to the poller.
struct RoutingHalt: Error {
  let outcome: HandleOutcome
}

/// How a handler recovers from a non-disk store failure: `retryUpdate` when nothing durable
/// happened yet (do not advance the cursor; the poller redelivers), `ack` when the effect's own
/// claim may have landed and the owner must be told the command failed so they can re-issue it.
enum StoreFailureReply: Sendable {
  case retryUpdate
  case ack(String)
}

/// Outbound plumbing shared by every handler family: dedup-claimed canned replies, command acks,
/// the storage-full notice, and — in `perform` — the ONE spelling of the router's two-tier
/// store-error contract (diskFull → notice + poller backoff; anything else → per-site recovery).
struct ReplySender: Sendable {
  let processed: any ProcessedUpdateStore
  let delivery: any MessageDelivery

  let logger: Logger

  /// Runs one store operation, mapping the failure classes every handler shares.
  func perform<Value: Sendable>(
    _ operation: String,
    updateID: Int64,
    target: DeliveryTarget,
    onFailure: StoreFailureReply = .retryUpdate,
    body: () throws -> Value
  ) async throws(RoutingHalt) -> Value {
    do {
      return try body()
    } catch StoreError.diskFull {
      throw RoutingHalt(outcome: await storageFull(target: target))
    } catch {
      logger.error("\(operation) failed for update \(updateID): \(error)")
      switch onFailure {
      case .retryUpdate:
        throw RoutingHalt(outcome: .transientFailure)
      case .ack(let text):
        throw RoutingHalt(
          outcome: await sendCommandAck(updateID: updateID, target: target, text: text)
        )
      }
    }
  }

  /// Claims the update for a direct effect (canned reply, verb, confirmation cancel) so a
  /// redelivery applies once. Returning normally means newly claimed — proceed; a duplicate or
  /// failed claim halts with the outcome the handler must return.
  func claimUpdate(updateID: Int64, target: DeliveryTarget) async throws(RoutingHalt) {
    let claimed = try await perform("update claim", updateID: updateID, target: target) {
      try processed.claimUpdate(updateID: updateID)
    }
    if !claimed {
      throw RoutingHalt(outcome: skipDuplicate(updateID: updateID))
    }
  }

  /// The one spelling of the duplicate-update outcome (dedup claims lose exactly one way).
  func skipDuplicate(updateID: Int64) -> HandleOutcome {
    logger.debug("duplicate update \(updateID), skipping")
    return .skipped
  }

  /// A direct canned reply, deduped via `claimUpdate` so a redelivery doesn't double-send it.
  func sendCanned(updateID: Int64, target: DeliveryTarget, text: String) async -> HandleOutcome {
    guard !Task.isCancelled else {
      return .transientFailure
    }

    do {
      try await claimUpdate(updateID: updateID, target: target)
    } catch {
      return error.outcome
    }

    do {
      _ = try await delivery.sendMessage(to: target, text: text)
    } catch {
      logger.error("send failed for update \(updateID): \(error)")
      return .transientFailure
    }

    return .processed
  }

  /// One claimed canned response delivered in stable chunk order.
  func sendCannedChunks(
    updateID: Int64,
    target: DeliveryTarget,
    texts: [String]
  ) async -> HandleOutcome {
    guard Task.isCancelled == false, texts.isEmpty == false else {
      return .transientFailure
    }

    do {
      try await claimUpdate(updateID: updateID, target: target)
    } catch {
      return error.outcome
    }

    do {
      for text in texts {
        _ = try await delivery.sendMessage(to: target, text: text)
      }
    } catch {
      logger.error("chunked send failed for update \(updateID): \(error)")
      return .transientFailure
    }
    return .processed
  }

  /// Ack for a command whose effect already claimed the update; the send is best-effort — a lost
  /// ack must not re-run the effect.
  func sendCommandAck(
    updateID: Int64,
    target: DeliveryTarget,
    text: String
  ) async -> HandleOutcome {
    do {
      _ = try await delivery.sendMessage(to: target, text: text)
    } catch {
      logger.error("command ack send failed for update \(updateID): \(error)")
    }
    return .processed
  }

  func sendPrivateBot(updateID: Int64, target: DeliveryTarget) async -> HandleOutcome {
    await sendCanned(updateID: updateID, target: target, text: MessageRouter.privateBotText)
  }

  /// Best-effort "storage full" notice (the send may still succeed — a full disk doesn't break
  /// the network) and the signal for the poller to back off without advancing the offset.
  func storageFull(target: DeliveryTarget) async -> HandleOutcome {
    do {
      _ = try await delivery.sendMessage(to: target, text: Degradation.storageFull)
    } catch {
      logger.error("failed to send storage-full notice: \(error)")
    }
    return .storageFull
  }
}
