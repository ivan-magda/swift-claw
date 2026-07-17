import ClawCore
import Foundation

/// Derives the `prompt_cache_key` the Responses route is asked to reuse a cached prefix under.
///
/// The key is a function of the static prefix alone — the instructions and the tool definitions —
/// so two runs sharing that prefix land on one cache entry however their sessions differ and
/// whatever order the tool registry happened to iterate in. Conversation text is deliberately not
/// folded in: a key that moved with every turn would make each recurring proactive run cache-cold,
/// which is the whole thing a cache key exists to prevent. The session identity travels in a header
/// instead, where it can vary without disturbing this.
///
/// The value leaves for the vendor, so it carries a digest and nothing else. No prompt text can
/// survive into it.
enum ChatGPTPromptCacheKey {
  static let prefix = "swift-claw:"

  /// Twelve digest bytes, rendered as twenty-four hex characters. Wide enough that two distinct
  /// prefixes colliding is not a practical concern for a cache hint, and narrow enough that the key
  /// stays a hint rather than becoming a durable fingerprint of an owner's configuration.
  static let digestByteCount = 12

  /// The key for a prefix, or nil when that prefix has no canonical encoding — which a tool schema
  /// carrying a non-finite number would cause, and which the caller reports rather than papering
  /// over with a key that stands for different content than it claims.
  static func make(instructions: String, tools: [ChatGPTWireTool]) -> String? {
    var encoded: [EncodedTool] = []
    encoded.reserveCapacity(tools.count)
    for tool in tools {
      guard let json = CanonicalJSON.encode(tool) else {
        return nil
      }
      encoded.append(EncodedTool(name: tool.name, json: json))
    }

    // Ordering here, and only here, is what frees the key from registry iteration order while the
    // request body still sends the tools exactly as it was handed them.
    encoded.sort { lhs, rhs in
      lhs.precedes(rhs)
    }

    var digestInput = Data()
    guard appendLengthPrefixed(Data(instructions.utf8), to: &digestInput) else {
      return nil
    }
    for tool in encoded {
      guard appendLengthPrefixed(Data(tool.json.utf8), to: &digestInput) else {
        return nil
      }
    }

    return prefix + SHA256Digest.hex(digestInput).prefix(digestByteCount * 2)
  }
}

// MARK: - Canonical Encoding

private extension ChatGPTPromptCacheKey {
  /// A tool's name beside its canonical JSON, kept together so the ordering cannot separate a name
  /// from the encoding whose place it decides.
  struct EncodedTool {
    let name: String
    let json: String

    /// Orders by raw UTF-8 bytes rather than by Swift's `String` comparison, so no collation or
    /// normalization rule — which have no business deciding a cache key — can move the digest. Two
    /// tools registered under one name are still ordered, by their encodings, rather than left to
    /// whatever the sort does with a tie.
    func precedes(_ other: EncodedTool) -> Bool {
      if name != other.name {
        return name.utf8.lexicographicallyPrecedes(other.name.utf8)
      }
      return json.utf8.lexicographicallyPrecedes(other.json.utf8)
    }
  }

  /// Frames each segment with its own byte count, so the digest reads one unambiguous list rather
  /// than a run of concatenated bytes: without this, empty instructions followed by a tool would
  /// hash identically to that tool's JSON supplied as the instructions.
  ///
  /// The count is converted rather than truncated. A length that could not be stated exactly would
  /// otherwise be stated wrongly, and a wrong frame is a key that stands for content it never saw.
  static func appendLengthPrefixed(_ segment: Data, to buffer: inout Data) -> Bool {
    guard let length = UInt64(exactly: segment.count) else {
      return false
    }
    withUnsafeBytes(of: length.bigEndian) { raw in
      buffer.append(contentsOf: raw)
    }
    buffer.append(segment)
    return true
  }
}
