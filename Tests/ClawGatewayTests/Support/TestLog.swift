import Logging

/// A silent logger for the gateway test suite. Components under test emit developer logs by design;
/// tests inject this no-op sink so the suite output stays quiet and deterministic. Use it wherever a
/// component under test requires a `Logger` and the test does not assert on log output.
enum TestLog {
  static let silent = Logger(label: "test.silent", factory: { _ in SwiftLogNoOpLogHandler() })
}
