import Foundation

public struct PinnedImageReference: Sendable, Equatable, CustomStringConvertible {
  public let repository: String
  public let digest: String

  public var registryHost: String {
    String(repository.split(separator: "/", maxSplits: 1)[0]).lowercased()
  }

  public var description: String {
    "\(repository)@sha256:\(digest)"
  }

  public static func parse(_ rawValue: String) -> PinnedImageReference? {
    guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    guard rawValue.contains("://") == false else {
      return nil
    }
    guard let separator = rawValue.range(of: "@sha256:") else {
      return nil
    }
    guard
      rawValue.range(
        of: "@sha256:",
        range: separator.upperBound..<rawValue.endIndex
      ) == nil
    else {
      return nil
    }

    let repository = String(rawValue[..<separator.lowerBound])
    let digest = String(rawValue[separator.upperBound...])
    guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      return nil
    }

    let components = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 2 else {
      return nil
    }
    let registry = String(components[0])
    guard isValidRegistryHost(registry) else {
      return nil
    }
    let repositoryComponents = components.dropFirst().map(String.init)
    guard repositoryComponents.allSatisfy(isValidRepositoryComponent) else {
      return nil
    }

    return PinnedImageReference(repository: repository, digest: digest)
  }

  package static func isValidRegistryHost(_ rawHost: String) -> Bool {
    guard rawHost == rawHost.lowercased(), rawHost.isEmpty == false else {
      return false
    }

    let pieces = rawHost.split(separator: ":", omittingEmptySubsequences: false)
    guard pieces.count <= 2 else {
      return false
    }

    if pieces.count == 2 {
      let rawPort = pieces[1]
      guard
        rawPort.isEmpty == false,
        rawPort.allSatisfy({ "0123456789".contains($0) }),
        let port = Int(rawPort),
        (1...65_535).contains(port)
      else {
        return false
      }
    }

    let hostname = String(pieces[0])
    guard hostname != "localhost", hostname.contains("."), hostname.contains("[") == false else {
      return false
    }

    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy(isValidDNSLabel) else {
      return false
    }
    guard labels.allSatisfy({ Int($0) != nil }) == false else {
      return false
    }

    return true
  }

  package static func isValidRepositoryComponent(_ component: String) -> Bool {
    guard component.isEmpty == false, component != ".", component != ".." else {
      return false
    }
    return component.allSatisfy { character in
      "abcdefghijklmnopqrstuvwxyz0123456789._-".contains(character)
    }
  }
}

// MARK: - Image Reference Validation

private extension PinnedImageReference {
  static func isValidDNSLabel(_ label: Substring) -> Bool {
    guard (1...63).contains(label.count), label.first != "-", label.last != "-" else {
      return false
    }
    return label.allSatisfy { character in
      "abcdefghijklmnopqrstuvwxyz0123456789-".contains(character)
    }
  }
}

extension PinnedImageReference {
  static let verifiedDefault = PinnedImageReference(
    repository: "cgr.dev/chainguard/python",
    digest: "55cd38584d1bba1913a1d58da07184cbe512724bc03e822e269404c73cd4c9cd"
  )
}

public struct ExecConfig: Sendable, Equatable {
  public let enabled: Bool
  public let image: PinnedImageReference?
  public let imageRegistryAllowlist: [String]
  public let memoryMiB: Int
  public let cpus: Int
  public let timeoutSeconds: Int
  public let allowEgress: Bool

  public static let disabledDefault = ExecConfig(
    enabled: false,
    image: nil,
    imageRegistryAllowlist: ["cgr.dev"],
    memoryMiB: 1024,
    cpus: 4,
    timeoutSeconds: 30,
    allowEgress: false
  )
}

// MARK: - Execution Parsing

extension AppConfig {
  static func parseExecConfig(from env: [String: String]) throws -> ExecConfig {
    let enabled = try boolValue(
      env[EnvKey.execEnabled],
      key: EnvKey.execEnabled,
      default: false
    )

    let registryAllowlist = try parseExecRegistryAllowlist(env[EnvKey.execImageRegistries])

    let rawImage = env[EnvKey.execImage] ?? ""
    let image: PinnedImageReference?

    if rawImage.isEmpty {
      image = enabled ? .verifiedDefault : nil
    } else if let parsed = PinnedImageReference.parse(rawImage) {
      image = parsed
    } else {
      throw ConfigError.invalidExecImage(rawImage)
    }

    if let image, !registryAllowlist.contains(image.registryHost) {
      throw ConfigError.execImageRegistryNotAllowed(image.registryHost)
    }

    let memoryMiB = try boundedExecInt(
      env[EnvKey.execMemoryMiB],
      default: EnvDefaults.execMemoryMiB,
      range: 256...8192,
      error: ConfigError.invalidExecMemoryMiB
    )

    let cpus = try boundedExecInt(
      env[EnvKey.execCPUs],
      default: EnvDefaults.execCPUs,
      range: 1...Int.max,
      error: ConfigError.invalidExecCPUs
    )
    if enabled, cpus > ProcessInfo.processInfo.activeProcessorCount {
      throw ConfigError.invalidExecCPUs("\(cpus)")
    }

    let timeoutSeconds = try boundedExecInt(
      env[EnvKey.execTimeout],
      default: EnvDefaults.execTimeoutSeconds,
      range: 1...300,
      error: ConfigError.invalidExecTimeout
    )

    let allowEgress = try boolValue(
      env[EnvKey.execAllowEgress],
      key: EnvKey.execAllowEgress,
      default: false
    )

    return ExecConfig(
      enabled: enabled,
      image: image,
      imageRegistryAllowlist: registryAllowlist,
      memoryMiB: memoryMiB,
      cpus: cpus,
      timeoutSeconds: timeoutSeconds,
      allowEgress: allowEgress
    )
  }

  private static func parseExecRegistryAllowlist(_ rawValue: String?) throws -> [String] {
    guard let rawValue else {
      return EnvDefaults.execImageRegistries
    }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      throw ConfigError.invalidExecImageRegistry(rawValue)
    }

    let hosts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { part in
      part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard hosts.isEmpty == false,
      hosts.allSatisfy(PinnedImageReference.isValidRegistryHost)
    else {
      throw ConfigError.invalidExecImageRegistry(rawValue)
    }

    return Array(Set(hosts)).sorted()
  }

  private static func boundedExecInt(
    _ rawValue: String?,
    default fallback: Int,
    range: ClosedRange<Int>,
    error: (String) -> ConfigError
  ) throws -> Int {
    let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard trimmed.isEmpty == false else {
      return fallback
    }

    guard let value = Int(trimmed), range.contains(value) else {
      throw error(trimmed)
    }

    return value
  }
}
