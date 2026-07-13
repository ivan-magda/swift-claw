import ClawCore
import Foundation

public actor FakeExecutionBackend: ExecutionBackend, SandboxMaintenance {
  private let availability: BackendAvailability
  private let health: SandboxHealth

  private var results: [ExecutionResult]
  private var requests: [ExecutionRequest] = []

  private var prepareCalls = 0
  private var shutdownCalls = 0
  private var admitting = true

  public init(
    availability: BackendAvailability = .available(engineVersion: "1.1.0"),
    health: SandboxHealth = .passingForTests,
    results: [ExecutionResult] = []
  ) {
    self.availability = availability
    self.health = health

    self.results = results
  }

  public func enqueue(_ result: ExecutionResult) {
    results.append(result)
  }

  public func probe() async -> BackendAvailability {
    availability
  }

  public func run(_ request: ExecutionRequest) async -> ExecutionResult {
    requests.append(request)
    guard results.isEmpty == false else {
      return ExecutionResult(
        terminationReason: .unavailable(reason: "no scripted execution result"),
        stdout: "",
        stderr: "",
        truncatedRawBytes: false,
        wallClock: .zero
      )
    }
    return results.removeFirst()
  }

  public func prepare() async -> SandboxHealth {
    prepareCalls += 1
    return health
  }

  public func shutdown() async {
    shutdownCalls += 1
  }

  public func isAdmitting() -> Bool {
    admitting
  }

  public func setAdmitting(_ value: Bool) {
    admitting = value
  }

  public func recordedRequests() -> [ExecutionRequest] {
    requests
  }

  public func prepareCallCount() -> Int {
    prepareCalls
  }

  public func shutdownCallCount() -> Int {
    shutdownCalls
  }
}
