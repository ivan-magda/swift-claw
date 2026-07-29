import Foundation

public struct ImageConfig: Sendable, Equatable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

// MARK: - Image Parsing

extension AppConfig {
  static func parseImageConfig(
    from env: [String: String]
  ) throws -> ImageConfig {
    let enabled = try boolValue(
      env[EnvKey.imageInput],
      key: EnvKey.imageInput,
      default: true
    )

    return ImageConfig(enabled: enabled)
  }
}
