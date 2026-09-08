import ClawCore
import Foundation

// MARK: - Ordered Section Assembly

extension ContextBuilder {
  func buildFixedSections(
    origin: RunOrigin,
    lessons: LessonSet?,
    ownerNotices: inout [String]
  ) -> [FittableSection] {
    [
      section(
        id: .policy,
        units: [
          SectionUnit(
            id: "policy",
            content: origin.isProactive ? proactiveSystemPrompt : systemPrompt,
            canTruncate: false
          )
        ]
      ),
      workspaceSection(
        id: .systemWorkspace,
        files: [.soul, .agents],
        cap: nil,
        ownerNotices: &ownerNotices
      ),
      workspaceSection(
        id: .tools,
        files: [.tools],
        cap: nil,
        ownerNotices: &ownerNotices
      ),
      section(
        id: .metadata,
        units: [
          SectionUnit(
            id: "metadata-time",
            content: "Current time: \(Self.iso8601(now()))",
            canTruncate: false
          )
        ]
      ),
      lessons.map(lessonsSection),
      workspaceSection(
        id: .userFile,
        files: [.user],
        cap: budget.userFileCap,
        ownerNotices: &ownerNotices
      ),
      workspaceSection(
        id: .memoryFile,
        files: [.memory],
        cap: budget.memoryFileCap,
        ownerNotices: &ownerNotices
      ),
    ].compactMap { $0 }
  }

  func buildTruncatableSections(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    origin: RunOrigin,
    residual: Int,
    excludeSensitiveMemory: Bool,
    ownerNotices: inout [String]
  ) -> [FittableSection] {
    [
      memoryItemsSection(excludeSensitive: excludeSensitiveMemory, residual: residual),
      historySection(snapshot: snapshot, residual: residual),
      // Proactive runs never recall: the retriever's dedup excludes only the CURRENT window,
      // so after a per-fire window reset a recall search would resurface exactly the prior-fire
      // turns (and the owner's DM chat about arming the job) that the reset fenced off.
      origin.isProactive
        ? nil
        : recallSection(snapshot: snapshot, sessionId: sessionId, residual: residual),
      skillsSection(residual: residual, ownerNotices: &ownerNotices),
    ].compactMap { $0 }
  }
}

// MARK: - Fixed Sections

private extension ContextBuilder {
  /// The row is uncapped and non-truncatable by its spec, so it is measured into the residual with
  /// the system rows: whatever the lessons cost, the truncatable rows share what is left.
  func lessonsSection(_ lessons: LessonSet) -> FittableSection {
    let body =
      lessons.lessons
      .enumerated()
      .map { index, lesson in
        "\(index + 1). \(lesson)"
      }
      .joined(separator: "\n")
    return section(
      id: .lessons,
      units: [SectionUnit(id: ContextRowID.lessons.rawValue, content: body, canTruncate: false)]
    )
  }

  func workspaceSection(
    id: ContextRowID,
    files: [WorkspaceFile],
    cap: Int?,
    ownerNotices: inout [String]
  ) -> FittableSection? {
    let units = files.compactMap { file -> SectionUnit? in
      let loaded = workspace.load(file: file, maxGraphemes: cap)

      switch loaded.outcome {
      case .present:
        if !loaded.text.isEmpty {
          return SectionUnit(
            id: file.relativePath,
            content: "## \(file.relativePath)\n\(loaded.text)",
            canTruncate: false
          )
        }
        return nil
      case .overCap:
        if let cap {
          let notice = """
            ⚠ `\(file.relativePath)` is \(loaded.graphemeCount)/\(cap) \
            — edit it to trim; left out this turn.
            """
          ownerNotices.append(notice)
        } else {
          warn("Workspace file \(file.relativePath) exceeded an uncapped load")
        }
        return nil
      case .missing:
        return nil
      case .unreadable:
        warn("Workspace file \(file.relativePath) could not be read")
        return nil
      }
    }

    guard units.isEmpty == false else {
      return nil
    }

    return section(id: id, units: units)
  }

  static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}

// MARK: - Row Budgets

extension ContextBuilder {
  func section(
    id: ContextRowID,
    cap: Int? = nil,
    dropMarker: DropMarker = .none,
    units: [SectionUnit]
  ) -> FittableSection {
    let spec = spec(for: id)
    return FittableSection(
      id: spec.id,
      tier: spec.tier,
      priority: spec.priority,
      truncatable: spec.truncatable,
      cap: cap ?? id.resolve(in: budget, residualGraphemes: nil),
      dropMarker: dropMarker,
      units: units
    )
  }

  func cap(for id: ContextRowID, residual: Int) -> Int {
    id.resolve(in: budget, residualGraphemes: residual) ?? Int.max
  }
}

// MARK: - Row Policy

private extension ContextBuilder {
  func spec(for id: ContextRowID) -> RowSpec {
    guard let spec = ContextRowPolicy.specs.first(where: { $0.id == id }) else {
      preconditionFailure("missing context row spec for \(id)")
    }
    return spec
  }
}
