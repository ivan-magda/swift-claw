import Testing

@testable import ClawCore

@Suite struct AttemptOutputLimiterTests {
  @Test func exactCapIsAcceptedAndOneMoreUnitIsRejectedAtBothInputSeams() throws {
    // given
    let streamedLimiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 4, maximumGraphemes: 4)
    )
    let streamedRound = streamedLimiter.beginRound()
    let terminalLimiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 4, maximumGraphemes: 4)
    )
    let terminalRound = terminalLimiter.beginRound()

    // when — both the incremental provider seam and terminal reconciliation land exactly at cap.
    try streamedRound.observe(fields: [AttemptOutputField(key: "visible", value: "1234")])
    try terminalRound.finalize(
      ChatResponse(
        content: "1234",
        finishReason: "stop",
        usage: nil,
        costFromProvider: nil
      )
    )

    // then — `>=` would reject the two calls above; omitting either `>` check would accept these.
    #expect(throws: ProviderError.localOutputLimit) {
      try streamedRound.observe(fields: [AttemptOutputField(key: "visible", value: "12345")])
    }
    #expect(throws: ProviderError.localOutputLimit) {
      try terminalRound.finalize(
        ChatResponse(
          content: "12345",
          finishReason: "stop",
          usage: nil,
          costFromProvider: nil
        )
      )
    }
  }

  @Test func toolArgumentsAndVisibleTextAccumulateAcrossRoundTrips() throws {
    // given
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 8, maximumGraphemes: 8)
    )
    let firstRound = limiter.beginRound()
    let secondRound = limiter.beginRound()

    // when
    try firstRound.observe(fields: [AttemptOutputField(key: "arguments", value: "12345")])
    #expect(throws: ProviderError.localOutputLimit) {
      try secondRound.observe(fields: [AttemptOutputField(key: "visible", value: "6789")])
    }

    // then
    #expect(
      limiter.counts
        == AttemptOutputCounts(utf8Bytes: 9, graphemes: 9, limitExceeded: true)
    )
  }

  @Test func graphemeAndUTF8LimitsRemainIndependent() throws {
    // given — one extended grapheme made from two UTF-8 scalars crosses only the byte bound
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 2, maximumGraphemes: 1)
    )
    let round = limiter.beginRound()

    // when
    #expect(throws: ProviderError.localOutputLimit) {
      try round.observe(fields: [AttemptOutputField(key: "visible", value: "e\u{301}")])
    }

    // then
    #expect(limiter.counts.graphemes == 1)
    #expect(limiter.counts.utf8Bytes == 3)
  }

  /// A shorter terminal restatement cannot refund streamed output to the next round. This kills a
  /// replace-with-latest counter while still avoiding double charging an ordinary restatement.
  @Test func shorterTerminalRestatementCannotReleaseTheRoundHighWaterMark() throws {
    // given
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 8, maximumGraphemes: 8)
    )
    let firstRound = limiter.beginRound()
    let secondRound = limiter.beginRound()
    try firstRound.observe(fields: [AttemptOutputField(key: "visible", value: "1234567")])

    // when — the terminal response restates less than the stream emitted
    try firstRound.finalize(
      ChatResponse(
        content: "1",
        finishReason: "stop",
        usage: nil,
        costFromProvider: nil
      )
    )

    // then — round two sees the retained high-water mark and crosses the attempt cap
    #expect(throws: ProviderError.localOutputLimit) {
      try secondRound.observe(fields: [AttemptOutputField(key: "visible", value: "89")])
    }
    #expect(limiter.counts.utf8Bytes == 9)
    #expect(limiter.counts.graphemes == 9)
  }

  /// Field-local high waters prevent a shrinking visible field from funding a growing tool field.
  /// This kills a whole-snapshot `max(previousTotal, newTotal)` implementation.
  @Test func shrinkingVisibleTextCannotRefundGrowingToolArgumentsInTheSameRound() throws {
    // given
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 12, maximumGraphemes: 12)
    )
    let round = limiter.beginRound()
    try round.observe(fields: [
      AttemptOutputField(key: "visible", value: "1234567890")
    ])

    // when
    #expect(throws: ProviderError.localOutputLimit) {
      try round.observe(fields: [
        AttemptOutputField(key: "visible", value: "1"),
        AttemptOutputField(key: "arguments", value: "abcdefghij"),
      ])
    }

    // then
    #expect(
      limiter.counts
        == AttemptOutputCounts(utf8Bytes: 20, graphemes: 20, limitExceeded: true)
    )
  }

  /// Stable keys keep a late lower-index field from inheriting an older field's array slot.
  @Test func lateFieldInsertionCannotShiftAndRefundAnExistingField() throws {
    // given
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 12, maximumGraphemes: 12)
    )
    let round = limiter.beginRound()
    try round.observe(fields: [AttemptOutputField(key: "item:2", value: "1234567890")])

    // when — item 1 appears later while item 2 shrinks
    #expect(throws: ProviderError.localOutputLimit) {
      try round.observe(fields: [
        AttemptOutputField(key: "item:1", value: "abcdefghij"),
        AttemptOutputField(key: "item:2", value: "1"),
      ])
    }

    // then
    #expect(limiter.counts.utf8Bytes == 20)
    #expect(limiter.counts.graphemes == 20)
  }

  @Test func graphemeLimitCanTripWhileTheByteLimitStillAllowsTheOutput() throws {
    // given
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 100, maximumGraphemes: 2)
    )
    let round = limiter.beginRound()

    // when
    #expect(throws: ProviderError.localOutputLimit) {
      try round.observe(fields: [AttemptOutputField(key: "visible", value: "abc")])
    }

    // then
    #expect(limiter.counts.utf8Bytes == 3)
    #expect(limiter.counts.graphemes == 3)
  }
}
