import ClawCore
import Foundation

/// Workspace skill LOAD: the model names a skill from the context index and gets that skill's
/// `SKILL.md` body back. The name is resolved against a fresh scan — a frontmatter string never
/// becomes a path component, and the model never types a path at all.
public struct SkillLoadTool: Tool {
  private let workspaceRoot: URL
  private let scanSkills: @Sendable () -> SkillScanResult
  private let redactor: SecretRedactor
  private let outputCapGraphemes: Int

  /// `scanSkills` is injected rather than a workspace: the scan lives behind Yams in
  /// `ClawWorkspace`, and `ClawTools` depends only on `ClawCore`.
  public init(
    workspaceRoot: URL,
    scanSkills: @escaping @Sendable () -> SkillScanResult,
    redactor: SecretRedactor,
    outputCapGraphemes: Int = ToolOutputCap.maxGraphemes
  ) {
    self.workspaceRoot = workspaceRoot
    self.scanSkills = scanSkills
    self.redactor = redactor
    self.outputCapGraphemes = outputCapGraphemes
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "skill_load",
      description: """
        Load one skill the owner installed, by the name the skills index spells. Returns the \
        skill's instructions to follow for the current task; an unknown name returns the \
        installed names.
        """,
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "name": .object([
            "type": .string("string"),
            "description": .string("The skill's name from the skills index, e.g. summarize"),
          ])
        ]),
        "required": .array([.string("name")]),
      ]),
      egressClass: .none,
      riskLevel: .safe,
      fenceLabel: WorkspaceSkills.fenceLabel
    )
  }

  public var timeout: Duration { .seconds(5) }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    nil  // nothing egresses; the name is resolved against the scan inside execute
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    guard
      let name = arguments.objectValue?["name"]?.stringValue,
      name.isEmpty == false
    else {
      return errorPayload("skill_load needs a non-empty \"name\" argument.")
    }

    let scan = scanSkills()
    let claimants = scan.descriptors.filter { descriptor in descriptor.name == name }
    guard claimants.count <= 1 else {
      let directories = claimants.map { descriptor in descriptor.directory.lastPathComponent }
      return errorPayload(Self.duplicateRefusal(name: name, directories: directories))
    }
    guard let descriptor = claimants.first else {
      let collided = Self.duplicateDirectories(for: name, in: scan.warnings)
      guard collided.isEmpty else {
        return errorPayload(Self.duplicateRefusal(name: name, directories: collided))
      }
      return unknownNamePayload(scan: scan)
    }

    return body(of: descriptor)
  }
}

// MARK: - Body Resolution

private extension SkillLoadTool {
  /// Containment is defence in depth: the scan already only yields directories it listed under
  /// `skills/`, but a symlinked skill directory must not serve a file from outside the workspace.
  /// The boundary is the workspace root rather than `skills/`, so the `skills` component is vetted
  /// too — anchoring on `skills/` would let a symlinked `skills/` redefine the boundary itself.
  func body(of descriptor: SkillDescriptor) -> ToolPayload {
    let relativePath = [
      WorkspaceSkills.directoryName,
      descriptor.directory.lastPathComponent,
      WorkspaceSkills.manifestName,
    ].joined(separator: "/")

    let manifestPath: String
    switch WorkspacePathContainment.resolveExisting(path: relativePath, root: workspaceRoot.path) {
    case .refused(let reason):
      return errorPayload(reason)
    case .resolved(let resolved):
      manifestPath = resolved
    }

    guard
      let data = FileManager.default.contents(atPath: manifestPath),
      let text = String(data: data, encoding: .utf8)
    else {
      return errorPayload("The skill \(descriptor.name) could not be read.")
    }
    // The scanner indexed this file through the same fence rule; a body that no longer parses
    // means the file changed under us, and guessing where it starts is worse than saying so.
    guard let document = FrontmatterFence.split(text) else {
      return errorPayload(
        "The skill \(descriptor.name) no longer has a valid --- frontmatter fence."
      )
    }

    // Frontmatter without a procedure under it is an authoring gap, not a skill: returning it as a
    // success would spend a tool call to hand the model an empty guidance fence and no reason why.
    guard document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      return errorPayload(
        "The skill \(descriptor.name) has no instructions under its frontmatter."
      )
    }

    return ToolPayload(
      content: ToolOutputCap.cap(redactor.redact(document.body), maxGraphemes: outputCapGraphemes),
      status: .ok,
      // A SKILL.md is owner-authored workspace material, like SOUL.md and AGENTS.md, which the
      // context injects untainted. Tainting here would suppress high-sensitivity memory for the
      // rest of the session as the price of following the owner's own procedure.
      ingestedUntrusted: false
    )
  }

  /// A miss is a SUCCESS: the model mistyped or hallucinated a name, and the installed names are
  /// exactly what lets it correct itself in the same turn. The requested name is never echoed —
  /// it is model-supplied text, and every payload here renders under the one fence label the
  /// prompt licenses as owner-authored guidance.
  func unknownNamePayload(scan: SkillScanResult) -> ToolPayload {
    let names = scan.descriptors.map(\.name).sorted()
    let content =
      names.isEmpty
      ? "That skill is not installed, and the workspace has no skills at all."
      : "That skill is not installed. Installed skills: \(names.joined(separator: ", "))."
    return ToolPayload(content: content, status: .ok, ingestedUntrusted: false)
  }

  func errorPayload(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }

  static func duplicateRefusal(name: String, directories: [String]) -> String {
    let claimants = directories.sorted().joined(separator: ", ")
    return """
      Several skill directories claim the name \(name) (\(claimants)), so I can't tell which one \
      you mean. Ask the owner to rename one of them.
      """
  }

  /// The directories that collided over `name`, empty when the scan reported no collision — a
  /// warning always names at least the two claimants that produced it.
  static func duplicateDirectories(for name: String, in warnings: [WorkspaceWarning]) -> [String] {
    for warning in warnings {
      if case .duplicateSkillName(let warnedName, let directories) = warning, warnedName == name {
        return directories
      }
    }
    return []
  }
}
