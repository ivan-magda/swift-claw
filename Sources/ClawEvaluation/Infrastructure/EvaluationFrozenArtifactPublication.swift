import ClawCore
import Foundation

/// Prepared canonical bytes keep frozen-artifact hashing and publication on one representation.
struct EvaluationFrozenArtifactPublication: Sendable {
  let data: Data
  let sha256: String

  init<Value: Encodable>(encoding value: Value) throws {
    let data = try CanonicalJSON.data(encoding: value)
    self.data = data
    sha256 = SHA256Digest.hex(data)
  }

  init(jsonObject: [String: Any]) throws {
    let data = try CanonicalJSON.data(fromJSONObject: jsonObject)
    self.data = data
    sha256 = SHA256Digest.hex(data)
  }

  @discardableResult
  func publish(to url: URL) throws -> String {
    try EvaluationDurablePublication.publish(data, to: url)
    return sha256
  }
}
