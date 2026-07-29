import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ImageCacheTests {
  private func photo(bytes: Int) -> ImagePart {
    ImagePart(
      data: Data(repeating: 0xFF, count: bytes),
      mediaType: .jpeg,
      width: 1280,
      height: 960
    )
  }

  @Test func storedImagesSurviveTheRunThatStoredThem() async {
    // given — the photo-then-question flow depends on this exact property
    let cache = ImageCache(maximumImages: 8, maximumBytes: 1_000_000)
    await cache.store(photo(bytes: 1_000), sessionId: 1, messageId: 100)

    // when — a later turn in the same session asks for what is still held
    let images = await cache.images(sessionId: 1)

    // then
    #expect(Set(images.keys) == [100])
  }

  @Test func sessionsDoNotSeeEachOthersImages() async {
    // given
    let cache = ImageCache(maximumImages: 8, maximumBytes: 1_000_000)
    await cache.store(photo(bytes: 1_000), sessionId: 1, messageId: 100)
    await cache.store(photo(bytes: 1_000), sessionId: 2, messageId: 200)

    // when
    let images = await cache.images(sessionId: 1)

    // then
    #expect(Set(images.keys) == [100])
  }

  @Test func aStoreOnlyReplacesTheEntryBelongingToItsOwnSession() async {
    // given — today's ids are messages-table row ids and so are globally unique, which is what keeps
    // this scenario off the product path; the key stays session-scoped so that a later move to a
    // per-chat identifier cannot turn a store into a delete of another session's photo
    let cache = ImageCache(maximumImages: 8, maximumBytes: 1_000_000)
    await cache.store(photo(bytes: 1_000), sessionId: 1, messageId: 100)

    // when
    await cache.store(photo(bytes: 1_000), sessionId: 2, messageId: 100)

    // then
    let first = await cache.images(sessionId: 1)
    let second = await cache.images(sessionId: 2)
    #expect(Set(first.keys) == [100])
    #expect(Set(second.keys) == [100])
  }

  @Test func evictsTheOldestEntryOnceTheEntryCapIsReached() async {
    // given
    let cache = ImageCache(maximumImages: 2, maximumBytes: 1_000_000)
    await cache.store(photo(bytes: 1_000), sessionId: 1, messageId: 100)
    await cache.store(photo(bytes: 1_000), sessionId: 1, messageId: 200)

    // when
    await cache.store(photo(bytes: 1_000), sessionId: 1, messageId: 300)

    // then — the oldest is what ages out
    let images = await cache.images(sessionId: 1)
    #expect(Set(images.keys) == [200, 300])
  }

  @Test func evictsOnceTheByteCeilingIsReached() async {
    // given
    let cache = ImageCache(maximumImages: 8, maximumBytes: 250_000)
    await cache.store(photo(bytes: 100_000), sessionId: 1, messageId: 100)
    await cache.store(photo(bytes: 100_000), sessionId: 1, messageId: 200)

    // when
    await cache.store(photo(bytes: 100_000), sessionId: 1, messageId: 300)

    // then
    let images = await cache.images(sessionId: 1)
    #expect(Set(images.keys) == [200, 300])
  }

  @Test func keepsASingleImageThatAlreadyExceedsTheByteCeiling() async {
    // given — refusing an oversized image is the selection layer's call, not the cache's
    let cache = ImageCache(maximumImages: 8, maximumBytes: 250_000)

    // when
    await cache.store(photo(bytes: 400_000), sessionId: 1, messageId: 100)

    // then
    let images = await cache.images(sessionId: 1)
    #expect(Set(images.keys) == [100])
  }

  @Test func restoringTheSameMessageReplacesItWithoutDoubleCountingItsBytes() async {
    // given — a re-download of the same message must not spend its bytes twice
    let cache = ImageCache(maximumImages: 8, maximumBytes: 250_000)
    await cache.store(photo(bytes: 100_000), sessionId: 1, messageId: 100)
    await cache.store(photo(bytes: 100_000), sessionId: 1, messageId: 100)

    // when — a second message fits only if the replaced bytes were released
    await cache.store(photo(bytes: 100_000), sessionId: 1, messageId: 200)

    // then
    let images = await cache.images(sessionId: 1)
    #expect(Set(images.keys) == [100, 200])
  }
}
