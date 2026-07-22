/// Whether doctor's results permit starting the daemon. An empty allowlist alone is the
/// expected onboarding state — the daemon must run for `/start` to reveal the owner's ID —
/// so it is start-ready, unlike any other failing check.
enum StartReadiness {
  case ready
  case readyAwaitingOwner
  case notReady

  static func from(reportOK: Bool, failingKeys: [String]) -> StartReadiness {
    if reportOK { return .ready }
    if failingKeys == ["allowlist.owners"] { return .readyAwaitingOwner }
    return .notReady
  }
}

/// The line a healthy `clawd doctor` ends with: the exact command that keeps the daemon
/// running, so a passing check never dead-ends. Silent while unhealthy or already running.
enum ServiceStartHint {
  static func text(
    readiness: StartReadiness,
    daemonRunning: Bool,
    unitInstalled: Bool,
    serviceManagerAvailable: Bool,
    isLinux: Bool,
    uid: UInt32
  ) -> String? {
    guard readiness != .notReady, !daemonRunning else { return nil }
    let opener =
      readiness == .readyAwaitingOwner
      ? "Checks passed (no owner allowlisted yet — start the daemon, then send /start "
        + "to your bot to get your ID)."
      : "All checks passed."
    guard unitInstalled else {
      return opener + " To keep clawd running as a service, see "
        + "https://github.com/ivan-magda/swift-claw/blob/main/docs/INSTALL.md"
    }
    guard serviceManagerAvailable else {
      return opener + " Start the daemon with: clawd run"
    }
    let startCommand =
      isLinux
      ? "systemctl --user enable --now swift-claw.service"
      : "launchctl bootstrap gui/\(uid) ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist"
    return opener + " Start the service:\n  " + startCommand
  }
}
