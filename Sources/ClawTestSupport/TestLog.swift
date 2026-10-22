import Logging

/// A silent logger for test suites. Components under test emit developer logs by design; tests
/// inject this no-op sink so the suite output stays quiet and deterministic. Use it wherever a
/// component under test requires a `Logger` and the test does not assert on log output.
public enum TestLog {
  public static let silent = Logger(label: "test.silent") { _ in
    SwiftLogNoOpLogHandler()
  }
}
