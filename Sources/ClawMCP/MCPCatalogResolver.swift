import ClawCore
import Foundation
import MCP

/// One remote tool, ready to become a `Tool`: named for the registry, schema repaired, description
/// capped, tier decided.
public struct ResolvedMCPTool: Sendable, Equatable {
  public let coordinate: MCPToolCoordinate
  public let localName: String
  public let description: String
  public let parameters: JSONValue
  public let riskLevel: RiskLevel

  public init(
    coordinate: MCPToolCoordinate,
    localName: String,
    description: String,
    parameters: JSONValue,
    riskLevel: RiskLevel
  ) {
    self.coordinate = coordinate
    self.localName = localName
    self.description = description
    self.parameters = parameters
    self.riskLevel = riskLevel
  }
}

/// What became of one server at boot. Retained rather than logged and forgotten: doctor and the
/// Telegram status reply both answer "why is that server's tool missing?" from this.
public struct MCPServerOutcome: Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case ok(toolCount: Int)
    case skipped(reason: String)
  }

  /// Cap on a skip reason. Failure text can quote a third party, and an owner-facing row is not a
  /// place to hand one an unbounded megaphone.
  public static let reasonLimit = 200

  public let server: String
  public let status: Status

  public init(server: String, status: Status) {
    self.server = server
    self.status = status
  }
}

/// The pinned catalog: what the registry advertises for this boot, plus how each server fared.
public struct ResolvedMCPCatalog: Sendable, Equatable {
  public let tools: [ResolvedMCPTool]
  public let outcomes: [MCPServerOutcome]

  public static let empty = ResolvedMCPCatalog(tools: [], outcomes: [])

  public init(tools: [ResolvedMCPTool], outcomes: [MCPServerOutcome]) {
    self.tools = tools
    self.outcomes = outcomes
  }
}

/// Turns live sessions into the boot catalog.
///
/// Servers are contacted concurrently but assembled in config order, because naming is assigned
/// across the whole declared set in one pass — order decides which tool keeps a contested name, and
/// deciding that by who answered first would rename tools between boots.
///
/// Nothing here throws. One server being unreachable, hostile, or oversized is a fact about that
/// server; the daemon and every other server carry on, and the reason is recorded for the owner.
public enum MCPCatalogResolver {
  public static func resolve(
    sessions: [MCPServerSession],
    metadataRedactor: SecretRedactor = SecretRedactor(secretValues: [])
  ) async -> ResolvedMCPCatalog {
    let discoveries = await discoverAll(sessions, metadataRedactor: metadataRedactor)
    let sanitizer = MCPMetadataSanitizer(redactor: metadataRedactor)

    var candidates: [Candidate] = []
    var outcomes: [MCPServerOutcome] = []

    for (session, discovery) in zip(sessions, discoveries) {
      let config = session.config

      switch discovery {
      case .skipped(let reason):
        outcomes.append(MCPServerOutcome(server: config.name, status: .skipped(reason: reason)))
      case .listed(let remoteTools):
        let kept = remoteTools.filter { remote in
          config.tools.allows(remote.name)
        }
        candidates.append(
          contentsOf: kept.map { remote in
            Candidate(config: config, remote: remote, sanitizer: sanitizer)
          }
        )
        outcomes.append(MCPServerOutcome(server: config.name, status: .ok(toolCount: kept.count)))
      }
    }

    let localNames = MCPToolNamer.assign(candidates.map(\.namingCoordinate))
    let tools = zip(candidates, localNames).map { candidate, localName in
      candidate.resolved(as: localName)
    }

    return ResolvedMCPCatalog(tools: tools, outcomes: outcomes)
  }
}

// MARK: - Discovery

private extension MCPCatalogResolver {
  enum Discovery: Sendable {
    case listed([MCP.Tool])
    case skipped(reason: String)
  }

  /// Runs discovery over a rolling window of `connectConcurrency` servers, then restores config
  /// order. A slow server delays only itself.
  static func discoverAll(
    _ sessions: [MCPServerSession],
    metadataRedactor: SecretRedactor
  ) async -> [Discovery] {
    await withTaskGroup(of: (offset: Int, discovery: Discovery).self) { group in
      var scheduled = 0
      var collected: [(offset: Int, discovery: Discovery)] = []
      collected.reserveCapacity(sessions.count)

      while scheduled < min(MCPDiscoveryLimits.connectConcurrency, sessions.count) {
        let offset = scheduled
        group.addTask {
          (offset, await discover(sessions[offset], metadataRedactor: metadataRedactor))
        }
        scheduled += 1
      }

      while let finished = await group.next() {
        collected.append(finished)
        guard scheduled < sessions.count else {
          continue
        }
        let offset = scheduled
        group.addTask {
          (offset, await discover(sessions[offset], metadataRedactor: metadataRedactor))
        }
        scheduled += 1
      }

      return
        collected
        .sorted { left, right in
          left.offset < right.offset
        }
        .map(\.discovery)
    }
  }

  static func discover(
    _ session: MCPServerSession,
    metadataRedactor: SecretRedactor
  ) async -> Discovery {
    do {
      try await session.connect()
      return .listed(try await session.listAllTools())
    } catch {
      // A half-open session is worse than none: drop it so nothing later calls into it.
      await session.disconnect()
      return .skipped(reason: skipReason(error, metadataRedactor: metadataRedactor))
    }
  }

  static func skipReason(_ error: any Error, metadataRedactor: SecretRedactor) -> String {
    let redacted = metadataRedactor.redact("\(error)")
    return TextTruncation.cap(redacted, maxGraphemes: MCPServerOutcome.reasonLimit)
  }
}

// MARK: - Candidates

private extension MCPCatalogResolver {
  /// A remote tool that survived its server's filter, still waiting for its registry name.
  struct Candidate {
    let config: MCPServerConfig
    let remote: MCP.Tool
    let sanitizer: MCPMetadataSanitizer

    var coordinate: MCPToolCoordinate {
      MCPToolCoordinate(server: config.name, remoteName: remote.name)
    }

    var namingCoordinate: MCPToolCoordinate {
      MCPToolCoordinate(
        server: sanitizer.text(config.name),
        remoteName: sanitizer.text(remote.name)
      )
    }

    func resolved(as localName: String) -> ResolvedMCPTool {
      ResolvedMCPTool(
        coordinate: coordinate,
        localName: localName,
        description: MCPDescriptionCap.cap(sanitizer.text(remote.description ?? "")),
        parameters: sanitizer.schema(
          MCPSchemaNormalizer.normalize(MCPValueBridge.jsonValue(remote.inputSchema))
        ),
        riskLevel: config.tools.riskLevel(for: remote.name)
      )
    }
  }
}
