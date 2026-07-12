import ClawCore
import Foundation

// MARK: - Canary

extension ContainerBackend {
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
    else {
      return nil
    }

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
    guard cleanupOK else {
      return nil
    }

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
    else {
      return nil
    }

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
    else {
      return nil
    }

    guard
      let guestData = await boundedCommandData(
        ContainerInvocation.execCanary(identity.name, script: Self.guestCanaryScript),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      ),
      let guest = try? JSONDecoder().decode(GuestCanaryDocument.self, from: guestData)
    else {
      return nil
    }

    let expectedDigest = "sha256:\(settings.workloadImage.digest)"

    let imageDigestOK =
      inspection.configuration.image.reference == settings.workloadImage.description
      && inspection.configuration.image.descriptor.digest == expectedDigest

    let memoryInBytes = UInt64(settings.memoryMiB) * 1024 * 1024
    let capsMatch =
      inspection.status.state == "running"
      && inspection.configuration.resources.cpus == settings.cpus
      && inspection.configuration.resources.memoryInBytes == memoryInBytes
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

struct GuestCanaryDocument: Decodable, Sendable {
  let capsEmpty: Bool
  let netIsolated: Bool
  let reaperOK: Bool
  let rootfsRO: Bool
  let stagingRO: Bool
  let interpretersOK: Bool
}

struct CanaryOutcome: Sendable {
  let imageDigestOK: Bool
  let capsMatch: Bool
  let guest: GuestCanaryDocument

  var isPassing: Bool {
    imageDigestOK
      && capsMatch
      && guest.capsEmpty
      && guest.netIsolated
      && guest.reaperOK
      && guest.rootfsRO
      && guest.stagingRO
      && guest.interpretersOK
  }
}
