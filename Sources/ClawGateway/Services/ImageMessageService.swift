import ClawCore
import Foundation
import Logging

/// Why an inbound photo produced no usable bytes, and the sentence the owner reads for it — so a
/// caller reports the refusal without inventing copy of its own.
public enum ImageMessageFailure: Error, Sendable, Equatable {
  /// The ladder carried no rung with a usable download handle.
  case unavailable
  /// The download exceeded the byte ceiling. The transport fails rather than truncating, because a
  /// short body is indistinguishable from a complete one and a truncated image must never be sent.
  case tooLarge
  /// The bytes are not any image format a vision route accepts.
  case undecodable
  /// The download failed for a transport reason.
  case fetchFailed
  /// The surrounding task was cancelled.
  case cancelled

  public var ownerReplyText: String {
    switch self {
    case .unavailable, .undecodable:
      "I couldn't read that image — try sending it again."
    case .tooLarge:
      "That image is too large for me to look at. Try a smaller one."
    case .fetchFailed:
      "I couldn't download that image. Try sending it again."
    case .cancelled:
      "I stopped before I could look at that image."
    }
  }
}

public protocol ImageMessageHandling: Sendable {
  func materialize(_ attachment: PhotoAttachment) async -> Result<ImagePart, ImageMessageFailure>
}

/// Turns a photo attachment into validated in-memory bytes. Nothing is written to disk: unlike a
/// voice note there is no external process to hand a file to, so the bytes live only as long as the
/// caller holds them.
public struct ImageMessageService: ImageMessageHandling {
  private let media: any MediaFetching
  private let maxBytes: Int
  private let logger: Logger

  public init(
    media: any MediaFetching,
    maxBytes: Int = ImageBounds.maximumImageBytes,
    logger: Logger
  ) {
    self.media = media
    self.maxBytes = maxBytes
    self.logger = logger
  }

  public func materialize(
    _ attachment: PhotoAttachment
  ) async -> Result<ImagePart, ImageMessageFailure> {
    // Declared metadata picks the rung before anything is fetched, but a sender can forge it, so
    // the same ceiling goes to the transport as the ground truth that actually binds.
    guard let rung = attachment.best(withinBytes: Int64(maxBytes)) else {
      return .failure(.unavailable)
    }

    let bytes: Data
    do {
      bytes = try await media.downloadFile(fileId: rung.fileId, maxBytes: maxBytes)
    } catch {
      // Each transport spells cancellation in its own error type, so the task's own state decides
      // whether this was a shutdown rather than a download that genuinely failed.
      if Task.isCancelled || error is CancellationError {
        return .failure(.cancelled)
      }
      // The classified reason, not the raw error: a transport description can echo the
      // token-bearing download URL.
      let failure = classify(error)
      logger.error("image download failed (reason=\(failure))")
      return .failure(failure)
    }

    guard let mediaType = ImageMediaType.sniff(bytes) else {
      return .failure(.undecodable)
    }

    // Only the shape is logged, never the bytes and never the token-bearing download URL.
    logger.info(
      "image ready (bytes=\(bytes.count) mime=\(mediaType.mimeType) \(rung.width)x\(rung.height))"
    )

    return .success(
      ImagePart(data: bytes, mediaType: mediaType, width: rung.width, height: rung.height)
    )
  }
}

// MARK: - Error Classification

private extension ImageMessageService {
  /// Recognizes the transport's refusal of a body past the ceiling *this* service asked for. That
  /// refusal is the only available signal, since an over-cap body is never handed back short.
  func classify(_ error: any Error) -> ImageMessageFailure {
    guard let transport = error as? HTTPTransportFailure else {
      return .fetchFailed
    }
    return transport.isOversizedBody(cap: maxBytes) ? .tooLarge : .fetchFailed
  }
}
