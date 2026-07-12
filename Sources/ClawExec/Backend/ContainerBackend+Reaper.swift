import ClawCore
import Foundation

// MARK: - Owned Reaper

extension ContainerBackend {
  func ownedContainers(deadline: ContinuousClock.Instant) async -> [ListedContainer]? {
    guard
      let containers = await listedContainers(
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      )
    else {
      return nil
    }

    return containers.filter { container in
      guard let identity = container.resolvedIdentifier else {
        return false
      }

      return identity.hasPrefix(ExecutionIdentity.namePrefix)
        && container.labels[ExecutionIdentity.ownershipLabelKey]
          == ExecutionIdentity.ownershipLabelValue
    }
  }

  func reapOwnedContainers(deadline: ContinuousClock.Instant) async -> Bool {
    guard let owned = await ownedContainers(deadline: deadline) else {
      return false
    }

    for container in owned {
      guard let identity = container.resolvedIdentifier else {
        return false
      }

      for step in ContainerInvocation.teardownLadder(identity) {
        _ = await boundedCommandSucceeded(
          step,
          limit: Self.lifecycleCommandTimeout,
          deadline: deadline
        )
      }
    }

    guard !owned.isEmpty else {
      return true
    }

    guard let remaining = await ownedContainers(deadline: deadline) else {
      return false
    }

    let expectedRemoved = Set(owned.compactMap(\.resolvedIdentifier))
    return remaining.allSatisfy { container in
      guard let identity = container.resolvedIdentifier else {
        return false
      }
      return !expectedRemoved.contains(identity)
    }
  }

  func sweepScratchRoots() -> Bool {
    let manager = FileManager.default

    for name in [ScratchWorkspace.scratchRootName, ScratchWorkspace.controlRootName] {
      let root = stateRoot.appending(path: name, directoryHint: .isDirectory)

      guard manager.fileExists(atPath: root.path) else {
        continue
      }

      guard
        let children = try? manager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil
        )
      else {
        return false
      }

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

extension ContainerBackend {
  func workloadDigestMatches(deadline: ContinuousClock.Instant) async -> Bool {
    guard
      let data = await boundedCommandData(
        ContainerInvocation.inspectImage(settings.workloadImage.description),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      )
    else {
      return false
    }

    guard let images = try? JSONDecoder().decode([ImageInspectDocument].self, from: data) else {
      return false
    }

    return images.contains { image in
      image.configuration.name == settings.workloadImage.description
        && image.configuration.descriptor.digest == "sha256:\(settings.workloadImage.digest)"
    }
  }
}
