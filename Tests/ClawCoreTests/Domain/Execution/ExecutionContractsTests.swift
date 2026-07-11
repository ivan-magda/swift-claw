import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore

@Suite struct ExecutionContractsTests {
  private let passingHealth = SandboxHealth(
    available: true,
    osOK: true,
    engineVersion: "1.1.0",
    versionOK: true,
    imageDigestOK: true,
    capsEmpty: true,
    netIsolated: true,
    capsMatch: true,
    reaperOK: true,
    rootfsRO: true,
    stagingRO: true,
    interpretersOK: true,
    lastError: nil
  )

  @Test func requestCarriesOnlyApprovedGuestInputs() {
    // given
    let entrypoint = StagedFile(
      name: ".clawd-entrypoint.py",
      bytes: Data("print('ok')".utf8),
      mode: .readExecute
    )
    let input = StagedFile(name: "notes.txt", bytes: Data("hello".utf8), mode: .readOnly)

    // when
    let request = ExecutionRequest(
      language: .python,
      entrypoint: entrypoint,
      inputs: [input],
      network: false,
      timeout: .seconds(30)
    )

    // then
    #expect(request.language == .python)
    #expect(request.entrypoint == entrypoint)
    #expect(request.inputs == [input])
    #expect(request.network == false)
    #expect(request.timeout == .seconds(30))
    #expect(FileMode.readOnly.rawValue == 0o400)
    #expect(FileMode.readExecute.rawValue == 0o500)
  }

  @Test func healthIsReadyOnlyWhenEveryGatePasses() {
    // given / when / then
    #expect(passingHealth.isReady)
    #expect(SandboxHealth.passingForTests == passingHealth)

    let failed = SandboxHealth(
      available: true,
      osOK: true,
      engineVersion: "1.1.0",
      versionOK: true,
      imageDigestOK: true,
      capsEmpty: true,
      netIsolated: false,
      capsMatch: true,
      reaperOK: true,
      rootfsRO: true,
      stagingRO: true,
      interpretersOK: true,
      lastError: "network escaped"
    )
    #expect(failed.isReady == false)
  }

  @Test func fakeRecordsRequestsAndNeverInventsSuccess() async {
    // given
    let scripted = ExecutionResult(
      terminationReason: .exited(code: 0),
      stdout: "ok\n",
      stderr: "",
      truncatedRawBytes: false,
      wallClock: .milliseconds(8)
    )
    let backend = FakeExecutionBackend(results: [scripted])
    let request = ExecutionRequest(
      language: .sh,
      entrypoint: StagedFile(
        name: ".clawd-entrypoint.sh",
        bytes: Data("printf ok".utf8),
        mode: .readExecute
      ),
      inputs: [],
      network: false,
      timeout: .seconds(5)
    )

    // when
    let first = await backend.run(request)
    let second = await backend.run(request)
    let health = await backend.prepare()
    await backend.shutdown()

    // then
    #expect(first == scripted)
    #expect(
      second.terminationReason
        == .unavailable(reason: "no scripted execution result")
    )
    #expect(await backend.recordedRequests() == [request, request])
    #expect(await backend.probe() == .available(engineVersion: "1.1.0"))
    #expect(health == .passingForTests)
    #expect(await backend.prepareCallCount() == 1)
    #expect(await backend.shutdownCallCount() == 1)
  }

  @Test func fakeCanBeReScriptedAfterConstruction() async {
    // given
    let backend = FakeExecutionBackend(results: [])
    let result = ExecutionResult(
      terminationReason: .timedOutKilled,
      stdout: "",
      stderr: "",
      truncatedRawBytes: false,
      wallClock: .seconds(2)
    )
    let request = ExecutionRequest(
      language: .python,
      entrypoint: StagedFile(name: "entry.py", bytes: Data(), mode: .readExecute),
      inputs: [],
      network: false,
      timeout: .seconds(1)
    )

    // when
    await backend.enqueue(result)

    // then
    #expect(await backend.run(request) == result)
  }
}
