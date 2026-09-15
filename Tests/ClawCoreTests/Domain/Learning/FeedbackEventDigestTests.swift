import ClawCore
import Testing

@Suite
struct FeedbackEventDigestTests {
  @Test
  func feedbackEventDigestChangesForEveryDurableEventField() throws {
    // given
    let baseline = FeedbackDigestInput()
    let baselineDigest = try baseline.digest()
    let changed = [
      (
        "event id",
        baseline.changing { input in
          input.eventID += 1
        }
      ),
      (
        "job id",
        baseline.changing { input in
          input.jobID += 1
        }
      ),
      (
        "learning epoch",
        baseline.changing { input in
          input.epoch = input.epoch.next()
        }
      ),
      (
        "subject kind",
        baseline.changing { input in
          input.subjectKind = .candidate
        }
      ),
      (
        "subject digest",
        baseline.changing { input in
          input.subjectDigest += "-changed"
        }
      ),
      (
        "signal",
        baseline.changing { input in
          input.signal = .resultNotUseful
        }
      ),
      (
        "payload",
        baseline.changing { input in
          input.payload += " changed"
        }
      ),
      (
        "actor",
        baseline.changing { input in
          input.actor = .system
        }
      ),
      (
        "transport update",
        baseline.changing { input in
          input.transportUpdateID += 1
        }
      ),
      (
        "feedback revision",
        baseline.changing { input in
          input.revision = input.revision.next()
        }
      ),
      (
        "supersedes",
        baseline.changing { input in
          input.supersedes += 1
        }
      ),
      (
        "occurrence time",
        baseline.changing { input in
          input.occurredAtEpochSecond += 1
        }
      ),
    ]

    // when
    let changedDigests = try changed.map { label, input in
      (label, try input.digest())
    }

    // then — omitting any one durable projection field would make that row mutation invisible
    #expect(
      baselineDigest.rawValue == "c64a1fa997dd7d4fabea90720d17b665efdbf2c84a6cae0c224c0ecd2689400f"
    )
    for (label, digest) in changedDigests {
      #expect(digest != baselineDigest, "digest omitted \(label)")
    }
  }
}

// MARK: - Fixtures

private struct FeedbackDigestInput {
  var eventID: Int64 = 7
  var jobID: Int64 = 11
  var epoch = LearningEpoch(2)
  var subjectKind = FeedbackSubjectKind.run
  var subjectDigest = "41"
  var signal = OwnerSignal.resultCorrection
  var payload = "owner correction"
  var actor = AuditActor.owner
  var transportUpdateID: Int64 = 800
  var revision = FeedbackRevision(3)
  var supersedes: Int64 = 6
  var occurredAtEpochSecond: Int64 = 1_782_000_600

  func changing(_ transform: (_ input: inout FeedbackDigestInput) -> Void) -> FeedbackDigestInput {
    var copy = self
    transform(&copy)
    return copy
  }

  func digest() throws -> FeedbackEventDigest {
    try FeedbackEventDigest.of(
      eventID: eventID,
      jobID: jobID,
      epoch: epoch,
      subjectKind: subjectKind,
      subjectDigest: subjectDigest,
      signal: signal,
      payload: payload,
      actor: actor,
      transportUpdateID: transportUpdateID,
      revision: revision,
      supersedes: supersedes,
      occurredAtEpochSecond: occurredAtEpochSecond
    )
  }
}
