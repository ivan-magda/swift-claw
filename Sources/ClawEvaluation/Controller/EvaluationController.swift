import ClawCore
import Foundation

struct EvaluationController: Sendable {
  let launcher: any EvaluationWorkerLaunching
  let freezeVerifier: any EvaluationFreezeVerifying

  init(
    launcher: any EvaluationWorkerLaunching = EvaluationSubprocessWorkerLauncher(),
    freezeVerifier: any EvaluationFreezeVerifying = EvaluationLiveFreezeVerifier()
  ) {
    self.launcher = launcher
    self.freezeVerifier = freezeVerifier
  }

}

extension EvaluationController {
  static func authorizeAttempt(
    _ configuration: EvaluationAttemptConfiguration,
    against freeze: EvaluationFreezeContext
  ) throws {
    try configuration.validate()
    try validate(configuration: configuration, against: freeze)
    guard FileManager.default.fileExists(atPath: configuration.resultURL.path) == false else {
      throw EvaluationControllerError.staleResultExists
    }
    let order = try EvaluationPageRunOrder.decode(
      freeze.runOrderJSON,
      approvedManifestSHA256: freeze.receipt.manifest.sha256
    )
    if configuration.stage == EvaluationPageStage.synthesis.rawValue {
      guard
        configuration.condition == .synthesis,
        configuration.frozenOrderKey == order.synthesis.orderKey
      else {
        throw EvaluationControllerError.frozenOrderMismatch
      }
      return
    }
    let matches = order.taskSlots.filter { slot in
      configuration.stage == slot.stage
        && configuration.frozenOrderIndex == slot.orderIndex
        && configuration.frozenOrderKey == slot.orderKey
        && configuration.split == slot.split
        && configuration.fixtureID == slot.fixtureID
        && configuration.replicate == slot.replicate
        && configuration.lessonSource == slot.lessonSource
        && configuration.condition.runOrderValue == slot.condition
    }
    guard matches.count == 1 else {
      throw EvaluationControllerError.frozenOrderMismatch
    }
    let restartSlots = try order.restartLifecycleSlots()
    let shouldPublishLesson = matches[0].orderKey == restartSlots.publisher.orderKey
    guard configuration.publishLessonAsActive == shouldPublishLesson else {
      throw EvaluationControllerError.frozenOrderMismatch
    }
  }

  static func authorizeCanaryProcess(
    _ configurations: [EvaluationAttemptConfiguration],
    against freeze: EvaluationFreezeContext
  ) throws {
    guard
      configurations.count == PageEvaluationContract.canaryAttemptsPerProcess,
      configurations[0].lessonSource == .clean,
      configurations[1].lessonSource == .artifact
        || configurations[1].lessonSource == .durableActive
    else {
      throw EvaluationControllerError.invalidCanaryTopology
    }
    for configuration in configurations {
      try configuration.validate()
      try validate(configuration: configuration, against: freeze)
      guard FileManager.default.fileExists(atPath: configuration.resultURL.path) == false else {
        throw EvaluationControllerError.staleResultExists
      }
    }
    let order = try EvaluationPageRunOrder.decode(
      freeze.runOrderJSON,
      approvedManifestSHA256: freeze.receipt.manifest.sha256
    )
    let matchingProcesses = order.canaryProcesses.filter { process in
      zip(configurations, process.attempts).allSatisfy { configuration, slot in
        configuration.fixtureID == slot.fixtureID
          && configuration.taskID == slot.taskID
          && configuration.lessonSource == slot.lessonSource
          && configuration.publishLessonAsActive == slot.publishActive
          && configuration.frozenOrderKey == slot.orderKey
      }
    }
    guard matchingProcesses.count == 1 else {
      throw EvaluationControllerError.frozenOrderMismatch
    }
  }
}

enum EvaluationControllerError: Error, Sendable, Equatable {
  case planPathMismatch
  case approvalBindingMismatch
  case provenanceBindingMismatch(String)
  case artifactBindingMismatch(String)
  case frozenOrderMismatch
  case invalidCanaryTopology
  case staleResultExists
  case resultIdentityMismatch
  case resultProgressMismatch
  case freezeChangedBeforeLaunch
  case replacementLineageMismatch
  case staleInvocationExists
  case sealedConfidentialityViolation
}
