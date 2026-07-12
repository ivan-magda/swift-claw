import ClawCore
import Foundation

extension ContainerBackend: ExecutionBackend, SandboxMaintenance {
  public func prepare() async -> SandboxHealth {
    preparedInitImage = nil
    do {
      try refuseIfBusy()
      let deadline = now().advanced(by: Self.prepareTimeout)
      let engineVersion = try await probeAndReap(deadline: deadline)
      let initImage = try await resolveInitImage(engineVersion: engineVersion, deadline: deadline)
      try await stageImages(
        engineVersion: engineVersion,
        initImage: initImage,
        deadline: deadline
      )
      return await verifyCanaryAndArm(
        engineVersion: engineVersion,
        initImage: initImage,
        deadline: deadline
      )
    } catch {
      return error.health
    }
  }

  public func shutdown() async {
    shuttingDown = true
    preparedInitImage = nil
    let executions = Array(executionTasks.values)
    for execution in executions { execution.cancel() }
    for execution in executions { _ = await execution.value }
    let cleanups = Array(cleanupTasks.values)
    for cleanup in cleanups { _ = await cleanup.value }
    let deadline = now().advanced(by: Self.prepareTimeout)
    _ = await reapOwnedContainers(deadline: deadline)
    _ = sweepScratchRoots()
  }

  var preparedInitImageForTesting: String? { preparedInitImage }

  func reapOwnedContainersForTesting() async -> Bool {
    await reapOwnedContainers(deadline: now().advanced(by: Self.prepareTimeout))
  }
}

// MARK: - Prepare Phases

/// Aborts the prepare pipeline carrying the failed health to report.
private struct PrepareAbort: Error {
  let health: SandboxHealth
}

private extension ContainerBackend {
  func refuseIfBusy() throws(PrepareAbort) {
    guard !shuttingDown else {
      throw PrepareAbort(health: failedHealth(lastError: "sandbox backend is shutting down"))
    }
    // New executions cannot be admitted while `preparedInitImage` is nil, so in-flight
    // work only needs this entry check; it cannot grow across prepare's awaits.
    guard executionTasks.isEmpty, cleanupTasks.isEmpty else {
      throw PrepareAbort(
        health: failedHealth(lastError: "sandbox prepare refused: executions in flight")
      )
    }
  }

  func probeAndReap(deadline: ContinuousClock.Instant) async throws(PrepareAbort) -> String {
    let availability = await probe()
    guard case .available(let engineVersion) = availability else {
      let reason =
        switch availability {
        case .available: "container engine is unavailable"
        case .unavailable(let reason): reason
        }
      throw PrepareAbort(health: failedHealth(lastError: reason))
    }
    guard await reapOwnedContainers(deadline: deadline), sweepScratchRoots() else {
      throw PrepareAbort(
        health: failedHealth(
          engineVersion: engineVersion,
          versionOK: true,
          lastError: "could not reap prior sandbox state"
        )
      )
    }
    return engineVersion
  }

  func resolveInitImage(
    engineVersion: String,
    deadline: ContinuousClock.Instant
  ) async throws(PrepareAbort) -> String {
    guard
      let propertyData = await boundedCommandData(
        ContainerInvocation.systemPropertyList(),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      ),
      let properties = try? JSONDecoder().decode(SystemPropertiesDocument.self, from: propertyData)
    else {
      throw PrepareAbort(
        health: failedHealth(
          engineVersion: engineVersion,
          versionOK: true,
          lastError: "could not read container runtime properties"
        )
      )
    }
    let initImage = properties.vminit.image
    guard RuntimeInitImageReference.isRegistryQualifiedTag(initImage) else {
      throw PrepareAbort(
        health: failedHealth(
          engineVersion: engineVersion,
          versionOK: true,
          lastError: "container runtime init image is not a registry-qualified tag"
        )
      )
    }
    return initImage
  }

  func stageImages(
    engineVersion: String,
    initImage: String,
    deadline: ContinuousClock.Instant
  ) async throws(PrepareAbort) {
    // Shutdown may complete while prepare is suspended; re-check before pulling images,
    // before launching the canary container, and before re-arming the init image so a
    // finished shutdown leaves no sandbox activity or prepared state behind.
    guard !shuttingDown else {
      throw PrepareAbort(
        health: failedHealth(
          engineVersion: engineVersion,
          versionOK: true,
          lastError: "sandbox backend is shutting down"
        )
      )
    }
    guard
      await boundedCommandSucceeded(
        ContainerInvocation.pull(settings.workloadImage.description),
        limit: Self.pullTimeout,
        deadline: deadline
      ),
      await boundedCommandSucceeded(
        ContainerInvocation.pull(initImage),
        limit: Self.pullTimeout,
        deadline: deadline
      )
    else {
      throw PrepareAbort(
        health: failedHealth(
          engineVersion: engineVersion,
          versionOK: true,
          lastError: "could not pull sandbox images"
        )
      )
    }
    guard await workloadDigestMatches(deadline: deadline) else {
      throw PrepareAbort(
        health: failedHealth(
          engineVersion: engineVersion,
          versionOK: true,
          lastError: "workload image digest did not match the configured pin"
        )
      )
    }
  }

  func verifyCanaryAndArm(
    engineVersion: String,
    initImage: String,
    deadline: ContinuousClock.Instant
  ) async -> SandboxHealth {
    guard !shuttingDown else {
      return failedHealth(
        engineVersion: engineVersion,
        versionOK: true,
        imageDigestOK: true,
        lastError: "sandbox backend is shutting down"
      )
    }
    guard let canary = await canaryOutcome(initImage: initImage, deadline: deadline) else {
      return failedHealth(
        engineVersion: engineVersion,
        versionOK: true,
        imageDigestOK: true,
        lastError: "sandbox canary did not complete"
      )
    }
    guard !shuttingDown else {
      return failedHealth(
        engineVersion: engineVersion,
        versionOK: true,
        imageDigestOK: true,
        lastError: "sandbox backend is shutting down"
      )
    }
    let health = SandboxHealth(
      available: true,
      osOK: true,
      engineVersion: engineVersion,
      versionOK: true,
      imageDigestOK: canary.imageDigestOK,
      capsEmpty: canary.guest.capsEmpty,
      netIsolated: canary.guest.netIsolated,
      capsMatch: canary.capsMatch,
      reaperOK: canary.guest.reaperOK,
      rootfsRO: canary.guest.rootfsRO,
      stagingRO: canary.guest.stagingRO,
      interpretersOK: canary.guest.interpretersOK,
      lastError: canary.isPassing ? nil : "sandbox canary hardening check failed"
    )
    if health.isReady {
      preparedInitImage = initImage
    }
    return health
  }
}

// MARK: - Owned Reaper

private extension ContainerBackend {
  func ownedContainers(deadline: ContinuousClock.Instant) async -> [ListedContainer]? {
    guard
      let containers = await listedContainers(
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      )
    else { return nil }
    return containers.filter { container in
      guard let identity = container.resolvedIdentifier else { return false }
      return identity.hasPrefix(ExecutionIdentity.namePrefix)
        && container.labels[ExecutionIdentity.ownershipLabelKey]
          == ExecutionIdentity.ownershipLabelValue
    }
  }

  func reapOwnedContainers(deadline: ContinuousClock.Instant) async -> Bool {
    guard let owned = await ownedContainers(deadline: deadline) else { return false }
    for container in owned {
      guard let identity = container.resolvedIdentifier else { return false }
      for step in ContainerInvocation.teardownLadder(identity) {
        _ = await boundedCommandSucceeded(
          step,
          limit: Self.lifecycleCommandTimeout,
          deadline: deadline
        )
      }
    }
    guard !owned.isEmpty else { return true }
    guard let remaining = await ownedContainers(deadline: deadline) else { return false }
    let expectedRemoved = Set(owned.compactMap(\.resolvedIdentifier))
    return remaining.allSatisfy { container in
      guard let identity = container.resolvedIdentifier else { return false }
      return !expectedRemoved.contains(identity)
    }
  }

  func sweepScratchRoots() -> Bool {
    let manager = FileManager.default
    for name in [ScratchWorkspace.scratchRootName, ScratchWorkspace.controlRootName] {
      let root = stateRoot.appending(path: name, directoryHint: .isDirectory)
      guard manager.fileExists(atPath: root.path) else { continue }
      guard
        let children = try? manager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil
        )
      else { return false }
      for child in children {
        do {
          try manager.removeItem(at: child)
        } catch {
          return false
        }
      }
    }
    return true
  }
}

// MARK: - Image Preparation

private extension ContainerBackend {
  func workloadDigestMatches(deadline: ContinuousClock.Instant) async -> Bool {
    guard
      let data = await boundedCommandData(
        ContainerInvocation.inspectImage(settings.workloadImage.description),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      )
    else { return false }
    guard let images = try? JSONDecoder().decode([ImageInspectDocument].self, from: data) else {
      return false
    }
    return images.contains { image in
      image.configuration.name == settings.workloadImage.description
        && image.configuration.descriptor.digest == "sha256:\(settings.workloadImage.digest)"
    }
  }
}

// MARK: - Canary

private extension ContainerBackend {
  func canaryOutcome(
    initImage: String,
    deadline: ContinuousClock.Instant
  ) async -> CanaryOutcome? {
    let identity = ExecutionIdentity()
    let request = ExecutionRequest(
      language: .python,
      entrypoint: StagedFile(
        name: ExecEntrypoint.fileName(for: .python),
        bytes: Data("# canary mount marker\n".utf8),
        mode: .readExecute
      ),
      inputs: [],
      network: false,
      timeout: Self.ordinaryCommandTimeout
    )
    guard
      let workspace = try? ScratchWorkspace.create(
        stateRoot: stateRoot,
        identity: identity,
        request: request
      )
    else { return nil }

    let evaluated = await evaluateCanary(
      identity: identity,
      workspace: workspace,
      initImage: initImage,
      deadline: deadline
    )
    let cleanupOK = await runShieldedCleanup(
      identity: identity,
      workspace: workspace
    )
    guard cleanupOK else { return nil }
    return evaluated
  }

  func evaluateCanary(
    identity: ExecutionIdentity,
    workspace: ScratchWorkspace,
    initImage: String,
    deadline: ContinuousClock.Instant
  ) async -> CanaryOutcome? {
    guard
      await boundedCommandSucceeded(
        ContainerInvocation.detachedCanary(
          identity: identity,
          scratchPath: workspace.directory.path,
          settings: settings,
          initImage: initImage
        ),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      )
    else { return nil }
    guard
      let inspectData = await boundedCommandData(
        ContainerInvocation.inspect(identity.name),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      ),
      let inspections = try? JSONDecoder().decode(
        [ContainerInspectDocument].self,
        from: inspectData
      ),
      let inspection = inspections.first(where: { $0.configuration.id == identity.name })
    else { return nil }
    guard
      let guestData = await boundedCommandData(
        ContainerInvocation.execCanary(identity.name, script: Self.guestCanaryScript),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      ),
      let guest = try? JSONDecoder().decode(GuestCanaryDocument.self, from: guestData)
    else { return nil }
    let expectedDigest = "sha256:\(settings.workloadImage.digest)"
    let imageDigestOK =
      inspection.configuration.image.reference == settings.workloadImage.description
      && inspection.configuration.image.descriptor.digest == expectedDigest
    let capsMatch =
      inspection.status.state == "running"
      && inspection.configuration.resources.cpus == settings.cpus
      && inspection.configuration.resources.memoryInBytes == UInt64(settings.memoryMiB) * 1024
        * 1024
      && inspection.configuration.readOnly
      && inspection.configuration.useInit
      && inspection.configuration.capAdd.isEmpty
      && inspection.configuration.capDrop == ["ALL"]
    return CanaryOutcome(imageDigestOK: imageDigestOK, capsMatch: capsMatch, guest: guest)
  }

  static var guestCanaryScript: String {
    """
    set -eu
    \(ExecSandboxSettings.pythonInterpreter) - <<'PY'
    import errno
    import json
    import os
    import socket

    def create_is_denied(path):
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
            os.unlink(path)
            return False
        except OSError as error:
            return error.errno in (errno.EROFS, errno.EACCES, errno.EPERM)

    def chmod_is_denied(path):
        try:
            os.chmod(path, 0o700)
            return False
        except OSError as error:
            return error.errno in (errno.EROFS, errno.EACCES, errno.EPERM)

    with open('/proc/self/status', encoding='utf-8') as status_file:
        cap_line = next(line for line in status_file if line.startswith('CapEff:'))
    caps_empty = int(cap_line.split()[1], 16) == 0
    interfaces = {name for _, name in socket.if_nameindex()}
    outbound = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    outbound.settimeout(0.25)
    try:
        outbound_reachable = outbound.connect_ex(('1.1.1.1', 53)) == 0
    finally:
        outbound.close()
    with open('/proc/1/comm', encoding='utf-8') as comm_file:
        reaper_ok = comm_file.read().strip() == '.cz-init'
    tmp_path = '/tmp/clawd-canary-write'
    with open(tmp_path, 'w', encoding='utf-8') as tmp_file:
        tmp_file.write('ok')
    os.unlink(tmp_path)
    rootfs_ro = create_is_denied('/clawd-canary-root-write')
    staging_ro = (
        create_is_denied('\(ExecEntrypoint.guestWorkDirectory)/clawd-canary-create')
        and chmod_is_denied('\(ExecEntrypoint.guestPath(for: .python))')
    )
    interpreters_ok = all(
        os.path.isfile(path) and os.access(path, os.X_OK)
        for path in ('\(ExecSandboxSettings.pythonInterpreter)', '\(ExecSandboxSettings.shellInterpreter)')
    )
    print(json.dumps({
        'capsEmpty': caps_empty,
        'netIsolated': interfaces == {'lo'} and not outbound_reachable,
        'reaperOK': reaper_ok,
        'rootfsRO': rootfs_ro,
        'stagingRO': staging_ro,
        'interpretersOK': interpreters_ok,
    }, sort_keys=True))
    PY
    """
  }
}

// MARK: - Health

private extension ContainerBackend {
  // reaperOK is guest evidence (/proc/1/comm observed by the canary); failed health always
  // reports it false because reaching a failure path means the canary never proved it.
  func failedHealth(
    engineVersion: String? = nil,
    versionOK: Bool = false,
    imageDigestOK: Bool = false,
    lastError: String
  ) -> SandboxHealth {
    SandboxHealth(
      available: engineVersion != nil,
      osOK: supportedHost(),
      engineVersion: engineVersion,
      versionOK: versionOK,
      imageDigestOK: imageDigestOK,
      capsEmpty: false,
      netIsolated: false,
      capsMatch: false,
      reaperOK: false,
      rootfsRO: false,
      stagingRO: false,
      interpretersOK: false,
      lastError: ownerSafe(lastError)
    )
  }
}

private struct SystemPropertiesDocument: Decodable {
  struct Vminit: Decodable { let image: String }
  let vminit: Vminit
}

private struct ImageInspectDocument: Decodable {
  struct Configuration: Decodable {
    struct Descriptor: Decodable { let digest: String }
    let name: String
    let descriptor: Descriptor
  }
  let configuration: Configuration
}

private struct ContainerInspectDocument: Decodable {
  struct Configuration: Decodable {
    struct Image: Decodable {
      struct Descriptor: Decodable { let digest: String }
      let reference: String
      let descriptor: Descriptor
    }
    struct Resources: Decodable {
      let cpus: Int
      let memoryInBytes: UInt64
    }
    let id: String
    let image: Image
    let labels: [String: String]
    let resources: Resources
    let readOnly: Bool
    let useInit: Bool
    let capAdd: [String]
    let capDrop: [String]
  }
  struct Status: Decodable { let state: String }
  let configuration: Configuration
  let status: Status
}

private struct GuestCanaryDocument: Decodable, Sendable {
  let capsEmpty: Bool
  let netIsolated: Bool
  let reaperOK: Bool
  let rootfsRO: Bool
  let stagingRO: Bool
  let interpretersOK: Bool
}

private struct CanaryOutcome: Sendable {
  let imageDigestOK: Bool
  let capsMatch: Bool
  let guest: GuestCanaryDocument

  var isPassing: Bool {
    imageDigestOK && capsMatch && guest.capsEmpty && guest.netIsolated && guest.reaperOK
      && guest.rootfsRO && guest.stagingRO && guest.interpretersOK
  }
}

private enum RuntimeInitImageReference {
  // Host/port and repository grammar defer to the same authority that validates the pinned
  // workload image, so the two reference checks cannot drift apart; only tag grammar is local.
  static func isRegistryQualifiedTag(_ value: String) -> Bool {
    guard
      !value.isEmpty,
      !value.contains("://"),
      !value.contains("@"),
      !value.contains(where: \.isWhitespace),
      let slash = value.firstIndex(of: "/")
    else { return false }
    let hostWithPort = String(value[..<slash])
    let repositoryWithTag = String(value[value.index(after: slash)...])
    guard let colon = repositoryWithTag.lastIndex(of: ":") else { return false }
    let repository = String(repositoryWithTag[..<colon])
    let tag = String(repositoryWithTag[repositoryWithTag.index(after: colon)...])
    guard !repository.isEmpty, !tag.isEmpty else { return false }
    guard PinnedImageReference.isValidRegistryHost(hostWithPort) else { return false }
    let components = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard
      components.allSatisfy({ component in
        PinnedImageReference.isValidRepositoryComponent(String(component))
      })
    else { return false }
    return tag.utf8.allSatisfy(isTagByte) && (tag.utf8.first.map(isTagStartByte) ?? false)
  }

  private static func isTagByte(_ byte: UInt8) -> Bool {
    isTagStartByte(byte) || byte == 0x2e || byte == 0x2d
  }

  private static func isTagStartByte(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
      || (byte >= 0x30 && byte <= 0x39) || byte == 0x5f
  }
}
