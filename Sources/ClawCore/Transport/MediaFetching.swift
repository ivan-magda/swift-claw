import Foundation

/// Fetches an inbound attachment's bytes by transport file handle. Media-agnostic on purpose: voice
/// notes and photos differ in what they mean, not in how they are downloaded.
public protocol MediaFetching: Sendable {
  func downloadFile(fileId: String, maxBytes: Int) async throws -> Data
}
