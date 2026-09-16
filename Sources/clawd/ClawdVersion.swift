/// The clawd version string.
///
/// Overwritten from the git tag by the release workflow
/// (`.github/workflows/release.yml`); stays `"0.0.0-dev"` for local and
/// unreleased builds so `clawd --version` never claims a release it isn't.
enum ClawdVersion {
  static let current = "0.0.0-dev"
}
