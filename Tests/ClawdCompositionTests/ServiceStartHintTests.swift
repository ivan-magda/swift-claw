import Testing

@testable import clawd

@Suite struct ServiceStartHintTests {
  @Test func healthyIdleMachineWithInstalledUnitGetsThePlatformStartCommand() {
    // given / when
    let macHint = ServiceStartHint.text(
      readiness: .ready,
      daemonRunning: false,
      unitInstalled: true,
      unitLoaded: false,
      serviceManagerAvailable: true,
      isLinux: false,
      uid: 501
    )
    let linuxHint = ServiceStartHint.text(
      readiness: .ready,
      daemonRunning: false,
      unitInstalled: true,
      unitLoaded: false,
      serviceManagerAvailable: true,
      isLinux: true,
      uid: 1000
    )

    // then
    #expect(macHint?.contains("launchctl bootstrap gui/501") == true)
    #expect(linuxHint?.contains("systemctl --user enable --now swift-claw.service") == true)
  }

  @Test func loadedButStoppedLaunchAgentGetsKickstartBecauseBootstrapWouldBeRejected() {
    // given / when
    let hint = ServiceStartHint.text(
      readiness: .ready,
      daemonRunning: false,
      unitInstalled: true,
      unitLoaded: true,
      serviceManagerAvailable: true,
      isLinux: false,
      uid: 501
    )

    // then
    #expect(hint?.contains("launchctl kickstart -k gui/501/com.ivanmagda.swift-claw") == true)
    #expect(hint?.contains("bootstrap") == false)
  }

  @Test func unloadedLaunchAgentStillGetsTheBootstrapCommand() {
    // given / when
    let hint = ServiceStartHint.text(
      readiness: .ready,
      daemonRunning: false,
      unitInstalled: true,
      unitLoaded: false,
      serviceManagerAvailable: true,
      isLinux: false,
      uid: 501
    )

    // then
    #expect(hint?.contains("launchctl bootstrap gui/501") == true)
    #expect(hint?.contains("kickstart") == false)
  }

  @Test func emptyAllowlistOnboardingStateStillGetsAStartCommandWithStartGuidance() {
    // given / when — the daemon must run for /start to reveal the owner's ID
    let hint = ServiceStartHint.text(
      readiness: .readyAwaitingOwner,
      daemonRunning: false,
      unitInstalled: true,
      unitLoaded: false,
      serviceManagerAvailable: true,
      isLinux: false,
      uid: 501
    )

    // then
    #expect(hint?.contains("launchctl bootstrap gui/501") == true)
    #expect(hint?.contains("/start") == true)
  }

  @Test func noHintWhileNotReadyOrAlreadyRunning() {
    // given / when / then — a failing report or a live daemon must not suggest starting
    #expect(
      ServiceStartHint.text(
        readiness: .notReady,
        daemonRunning: false,
        unitInstalled: true,
        unitLoaded: false,
        serviceManagerAvailable: true,
        isLinux: false,
        uid: 501
      ) == nil
    )
    #expect(
      ServiceStartHint.text(
        readiness: .ready,
        daemonRunning: true,
        unitInstalled: true,
        unitLoaded: true,
        serviceManagerAvailable: true,
        isLinux: false,
        uid: 501
      ) == nil
    )
  }

  @Test func missingUnitOrServiceManagerFallsBackHonestly() {
    // given / when
    let noUnit = ServiceStartHint.text(
      readiness: .ready,
      daemonRunning: false,
      unitInstalled: false,
      unitLoaded: false,
      serviceManagerAvailable: true,
      isLinux: false,
      uid: 501
    )
    let noSystemd = ServiceStartHint.text(
      readiness: .ready,
      daemonRunning: false,
      unitInstalled: true,
      unitLoaded: false,
      serviceManagerAvailable: false,
      isLinux: true,
      uid: 1000
    )

    // then — never print a command the machine cannot run
    #expect(noUnit?.contains("docs/INSTALL.md") == true)
    #expect(noSystemd?.contains("clawd run") == true)
    #expect(noSystemd?.contains("systemctl") == false)
  }
}
