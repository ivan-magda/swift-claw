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
    for execution in executions {
      execution.cancel()
    }
    for execution in executions {
      _ = await execution.value
    }

    let cleanups = Array(cleanupTasks.values)
    for cleanup in cleanups {
      _ = await cleanup.value
    }

    let deadline = now().advanced(by: Self.prepareTimeout)
    _ = await reapOwnedContainers(deadline: deadline)

    _ = sweepScratchRoots()
  }

  var preparedInitImageForTesting: String? {
    preparedInitImage
  }

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
