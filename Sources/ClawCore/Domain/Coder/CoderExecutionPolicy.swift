/// Non-secret native execution facts resolved once by composition and shared across approval seams.
public struct CoderExecutionPolicy: Sendable, Equatable {
  public let id: String

  public init(
    executable: String,
    profile: String?,
    configHome: String?,
    approvalPolicy: String,
    credentialSources: [String: String],
    searchPath: String? = nil
  ) {
    var parts = [executable]

    for optional in [profile, configHome] {
      if let optional {
        parts += ["present", optional]
      } else {
        parts.append("absent")
      }
    }

    parts.append(approvalPolicy)

    for key in credentialSources.keys.sorted() {
      parts += [key, credentialSources[key] ?? ""]
    }

    if let searchPath {
      parts += ["PATH", searchPath]
    }

    id = PolicyFingerprint.hash(parts: parts)
  }
}
