import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum CodexReportStatus: String, Sendable, Codable {
  case succeeded, blocked, failed
}

// swiftlint:disable discouraged_optional_collection
struct CodexReport: Sendable, Decodable {
  static let byteLimit = 64 * 1024
  let status: CodexReportStatus
  let summary: String
  let startingCommit: String?
  let baseBranch: String?
  let changedFiles: [String]?
  let branch: String?
  let commit: String?
  let prURL: String?
  let checks: [String]
  let error: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case status, summary, branch, commit, checks, error
    case startingCommit = "starting_commit"
    case baseBranch = "base_branch"
    case changedFiles = "changed_files"
    case prURL = "pr_url"
  }

  static func decode(at path: String) throws -> CodexReport {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CodexProtocolFailure.invalidReport
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0, metadata.st_size <= byteLimit
    else {
      throw CodexProtocolFailure.invalidReport
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0, errno == EINTR { continue }
      guard count > 0, data.count + count <= byteLimit else {
        throw CodexProtocolFailure.invalidReport
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue))
    else {
      throw CodexProtocolFailure.invalidReport
    }
    return try JSONDecoder().decode(Self.self, from: data)
  }
}
// swiftlint:enable discouraged_optional_collection

enum CodexProtocolFailure: Error {
  case invalidReport, invalidEvents
}
