import ClawWorkspace
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

/// The pinned lesson row: a job's frozen lessons reach the model as untrusted, fenced, whole data —
/// or the assembly fails. Substituting a truncated set would evaluate a hypothesis the binding
/// never froze, and emitting the row at the system tier would turn advisory data into authority.
@Suite("Lesson row")
struct LessonRowTests {
  @Test func lessonsRenderInsideTheFenceAndAreNeverSplitAcrossTiers() throws {
    // given — a set at the algorithm's per-lesson ceiling, and a workspace whose own untrusted
    // rows share the fence, so the assertion is about this row and not about being the only one
    let lessons = [
      String(repeating: "a", count: LessonSetLimits.maxLessonBytes),
      String(repeating: "b", count: LessonSetLimits.maxLessonBytes),
    ]
    let set = try LessonSet.canonical(jobId: 7, lessons: lessons)
    let builder = makeLessonBuilder(
      workspace: FakeWorkspace(files: [.user: .present("owner profile")])
    )

    // when
    let result = try builder.assemble(
      snapshot: lessonSnapshot(),
      sessionId: 1,
      origin: .scheduled,
      lessons: set
    )

    // then — one untrusted user message carries the whole set behind the label, and no system row
    // ever repeats it
    let untrusted = try #require(
      result.messages.first { message in message.role == .user }
    ).content.text
    #expect(untrusted.contains("label=\"\(ContextBuilder.lessonsLabel)\""))
    #expect(untrusted.contains(lessons[0]))
    #expect(untrusted.contains(lessons[1]))
    let system = try #require(result.messages.first { message in message.role == .system })
    #expect(system.content.text.contains(lessons[0]) == false)
  }

  @Test func anEmptySetEmitsNoRowAndLeavesSensitiveMemoryReachable() throws {
    // given
    let memoryStore = FakeMemoryStore(items: [lessonMemory()])
    let builder = makeLessonBuilder(memoryStore: memoryStore)

    // when
    let result = try builder.assemble(
      snapshot: lessonSnapshot(),
      sessionId: 1,
      origin: .scheduled,
      lessons: LessonSet.empty(jobId: 7)
    )

    // then — an empty set is not a row, and it raises no taint of its own
    let rendered = result.messages.map(\.content.text).joined(separator: "\n")
    #expect(rendered.contains(ContextBuilder.lessonsLabel) == false)
    #expect(memoryStore.fetchRankedCalls == [false])
    #expect(rendered.contains("clearance code"))
  }

  @Test func lessonTaintAugmentsPersistedSessionTaintInsteadOfReplacingIt() throws {
    // given — an untainted session with lessons, and a tainted session without them
    let set = try LessonSet.canonical(jobId: 7, lessons: ["Report only price changes."])
    let withLessonsMemory = FakeMemoryStore(items: [lessonMemory()])
    let withoutLessonsMemory = FakeMemoryStore(items: [lessonMemory()])

    // when
    let withLessons = try makeLessonBuilder(memoryStore: withLessonsMemory).assemble(
      snapshot: lessonSnapshot(isTainted: false),
      sessionId: 1,
      origin: .scheduled,
      lessons: set
    )
    let withoutLessons = try makeLessonBuilder(memoryStore: withoutLessonsMemory).assemble(
      snapshot: lessonSnapshot(isTainted: true),
      sessionId: 1,
      origin: .scheduled,
      lessons: LessonSet.empty(jobId: 7)
    )

    // then — each input excludes sensitive memory on its own; neither replaces the other
    #expect(withLessonsMemory.fetchRankedCalls == [true])
    #expect(withoutLessonsMemory.fetchRankedCalls == [true])
    #expect(withLessons.messages.joinedText.contains("clearance code") == false)
    #expect(withoutLessons.messages.joinedText.contains("clearance code") == false)
  }

  @Test func aSetTheBudgetCannotHoldFailsTheAssemblyInsteadOfTruncating() throws {
    // given — an input cap every other row of this run fits inside, with no room for a lesson
    let set = try LessonSet.canonical(
      jobId: 7,
      lessons: [String(repeating: "a", count: LessonSetLimits.maxLessonBytes)]
    )
    let builder = makeLessonBuilder(budget: lessonBudget(inputCapGraphemes: 200))
    let unbound = try builder.assemble(
      snapshot: lessonSnapshot(),
      sessionId: 1,
      origin: .scheduled,
      lessons: nil
    )
    #expect(unbound.messages.isEmpty == false)

    // when / then — the same run, bound, fails before a provider ever sees a shortened set
    #expect(throws: BudgetFitterError.self) {
      try builder.assemble(
        snapshot: lessonSnapshot(),
        sessionId: 1,
        origin: .scheduled,
        lessons: set
      )
    }
  }
}

// MARK: - Fixture

private extension [ChatMessage] {
  var joinedText: String {
    map(\.content.text).joined(separator: "\n")
  }
}

private func lessonBudget(inputCapGraphemes: Int) -> ContextBudget {
  ContextBudget(
    inputCapGraphemes: inputCapGraphemes,
    userFileCap: 1_375,
    memoryFileCap: 2_200,
    itemsCap: 1_500,
    historyCap: 6_000,
    recallCap: 2_000,
    skillsCap: 4_000,
    recallHitCap: 400
  )
}

private func makeLessonBuilder(
  workspace: FakeWorkspace = FakeWorkspace(),
  memoryStore: FakeMemoryStore = FakeMemoryStore(),
  budget: ContextBudget = .default
) -> ContextBuilder {
  ContextBuilder(
    systemPrompt: "system policy",
    proactiveSystemPrompt: "proactive policy",
    workspace: workspace,
    memoryStore: memoryStore,
    retriever: EmptyRetriever(),
    budget: budget,
    now: { Date(timeIntervalSince1970: 0) }
  )
}

private func lessonSnapshot(isTainted: Bool = false) -> SessionContextSnapshot {
  SessionContextSnapshot(
    sessionKey: SessionKey.scheduledJob(id: 7),
    history: [StoredMessage(role: .user, content: "run the job", provenance: .trusted)],
    historyMessageIds: [1],
    windowStartMessageId: 0,
    isTainted: isTainted,
    hasPrivateData: false
  )
}

/// One high-sensitivity item: the memory taint is observable only as what the ranker withholds.
private func lessonMemory() -> MemoryItem {
  MemoryItem(
    id: 1,
    text: "clearance code",
    kind: .project,
    sensitivity: .high,
    importance: .high,
    source: .owner,
    sessionId: nil,
    createdAt: Date(timeIntervalSince1970: 1)
  )
}
