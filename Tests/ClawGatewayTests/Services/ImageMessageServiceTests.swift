import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ImageMessageServiceTests {
  private let ladder = PhotoAttachment(sizes: [
    PhotoSize(fileId: "s-id", fileUniqueId: "s-u", width: 90, height: 67, fileSizeBytes: 1_466),
    PhotoSize(
      fileId: "y-id",
      fileUniqueId: "y-u",
      width: 1280,
      height: 960,
      fileSizeBytes: 186_422
    ),
  ])
  private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

  private func makeService(
    fetcher: any MediaFetching,
    maxBytes: Int = ImageBounds.maximumImageBytes
  ) -> ImageMessageService {
    ImageMessageService(media: fetcher, maxBytes: maxBytes, logger: TestLog.silent)
  }

  @Test func downloadsTheLargestAffordableRungAndSniffsIt() async throws {
    // given
    let fetcher = StubMediaFetcher(result: .success(jpeg))
    let service = makeService(fetcher: fetcher)

    // when
    let outcome = await service.materialize(ladder)

    // then — the 1280 rung wins, and the cap reaches the transport as ground truth
    let image = try outcome.get()
    #expect(image.mediaType == .jpeg)
    #expect(image.width == 1280)
    #expect(image.height == 960)
    #expect(image.data == jpeg)
    let expected = StubMediaFetcher.Call(fileId: "y-id", maxBytes: ImageBounds.maximumImageBytes)
    #expect(await fetcher.calls == [expected])
  }

  @Test func refusesAPayloadThatIsNotAnImage() async {
    // given — a truncated or hostile body must never reach a vision model
    let fetcher = StubMediaFetcher(result: .success(Data("<!DOCTYPE html>".utf8)))
    let service = makeService(fetcher: fetcher)

    // when
    let outcome = await service.materialize(ladder)

    // then
    #expect(outcome.isFailure(.undecodable))
  }

  @Test func refusesWhenTheLadderHasNoUsableRung() async {
    // given
    let fetcher = StubMediaFetcher(result: .success(jpeg))
    let service = makeService(fetcher: fetcher)

    // when
    let outcome = await service.materialize(PhotoAttachment(sizes: []))

    // then — nothing is fetched
    #expect(outcome.isFailure(.unavailable))
    #expect(await fetcher.calls.isEmpty)
  }

  @Test func mapsAnOversizedDownloadToItsOwnOwnerReply() async {
    // given — a distinctive ceiling, so a hardcoded constant cannot pass by luck
    let cap = 4_096
    let fetcher = StubMediaFetcher(result: .failure(HTTPTransportFailure.oversizedBody(cap: cap)))
    let service = makeService(fetcher: fetcher, maxBytes: cap)

    // when
    let outcome = await service.materialize(ladder)

    // then
    #expect(outcome.isFailure(.tooLarge))
  }

  @Test func mapsAnUnremarkableTransportErrorToADownloadFailure() async {
    // given
    let fetcher = StubMediaFetcher(audio: nil)
    let service = makeService(fetcher: fetcher)

    // when
    let outcome = await service.materialize(ladder)

    // then — distinct from .tooLarge: retrying is worth suggesting here
    #expect(outcome.isFailure(.fetchFailed))
  }

  @Test func aCancelledTaskReportsCancellationRatherThanADownloadFailure() async {
    // given — a transport that reports cancellation as an ordinary error of its own
    let service = makeService(fetcher: ParkUntilCancelledFetcher())

    // when
    let running = Task {
      await service.materialize(ladder)
    }
    running.cancel()
    let outcome = await running.value

    // then — a shutdown is not a broken download, and the owner copy says so
    #expect(outcome.isFailure(.cancelled))
  }

  @Test func refusalsReadDifferentlyWhereTheOwnerWouldActDifferently() {
    // given — the four causes an owner can respond to: send a different photo, send a smaller one,
    // retry, or wait out a shutdown
    let actionable: [ImageMessageFailure] = [.unavailable, .tooLarge, .fetchFailed, .cancelled]

    // when
    let replies = actionable.map(\.ownerReplyText)

    // then — an oversized photo names its own cause instead of reading as a broken download
    #expect(Set(replies).count == replies.count)

    // … while "no usable rung" and "not an image" share one sentence on purpose: neither leaves the
    // owner anything to do but send the picture again
    let unreadableCopy = ImageMessageFailure.unavailable.ownerReplyText
    #expect(ImageMessageFailure.undecodable.ownerReplyText == unreadableCopy)
  }
}
