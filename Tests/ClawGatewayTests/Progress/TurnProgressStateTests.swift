import ClawCore
import ClawGateway
import Testing

@Suite
struct TurnProgressStateTests {
  @Test
  func workingStepsCollapseAndStayWithinBounds() {
    // given
    var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [])
    state.apply(.modelStarted(providerCallID: "round"))

    // when
    for index in 0...TurnProgressLimits.retainedToolSteps {
      let id = TurnToolStepID(providerCallID: "round", toolCallID: "\(index)")
      state.apply(.toolStarted(id: id, tool: tool("web_search"), preview: "query"))
      state.apply(.toolState(id: id, state: .succeeded))
    }
    state.apply(.answerPreview("answer"))
    let snapshot = state.snapshot(elapsedSeconds: 14)

    // then
    #expect(snapshot.steps.count == TurnProgressLimits.retainedToolSteps)
    #expect(snapshot.olderSteps.succeeded == 1)
    #expect(snapshot.phase == .answer)
    #expect(snapshot.answerPreview == "answer")
  }

  @Test
  func latestExplanationResetsReplacementAndProviderNamespace() {
    // given
    let secret = "synthetic-token"
    var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [secret])
    state.apply(.modelStarted(providerCallID: "first"))

    // when
    state.apply(.explanation(explanation(.append("checking synthetic-"))))
    let partial = state.snapshot(elapsedSeconds: 1)
    state.apply(.explanation(explanation(.append("token done"))))
    let complete = state.snapshot(elapsedSeconds: 2)
    state.apply(.explanation(explanation(.replace("replacement"))))
    let replaced = state.snapshot(elapsedSeconds: 3)
    state.apply(.explanation(explanation(.append(String(repeating: "x", count: 1_000)))))
    let capped = state.snapshot(elapsedSeconds: 4)
    state.apply(.modelStarted(providerCallID: "second"))
    state.apply(.explanation(explanation(.append("new"))))
    state.apply(.explanation(explanation(.complete)))
    let next = state.snapshot(elapsedSeconds: 5)

    // then
    #expect(partial.explanation == "checking")
    #expect(complete.explanation == "checking " + SecretRedactor.replacement + " done")
    #expect(replaced.explanation == "replacement")
    #expect(capped.explanation?.count == TurnProgressLimits.explanationCharacters)
    #expect(next.explanation == "new")
  }

  @Test
  func normalizedExplanationWithholdsSecretPrefixesAcrossAppendBoundaries() {
    // given
    let cases = [
      ("synthetic-\u{202E}", "token", "synthetic-token"),
      ("synthetic\t", "\t token", "synthetic token"),
    ]

    // when
    for (first, second, secret) in cases {
      var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [secret])
      state.apply(.modelStarted(providerCallID: "round"))
      state.apply(.explanation(explanation(.append("checking " + first))))
      let partial = state.snapshot(elapsedSeconds: 1)
      state.apply(.explanation(explanation(.append(second))))
      let completed = state.snapshot(elapsedSeconds: 2)
      state.apply(.explanation(explanation(.complete)))
      let flushed = state.snapshot(elapsedSeconds: 3)

      // then
      #expect(partial.explanation == "checking")
      #expect(completed.explanation == "checking " + SecretRedactor.replacement)
      #expect(flushed.explanation == completed.explanation)
    }
  }

  @Test
  func toolFamiliesExposeOnlyAllowedRegisteredPreviews() throws {
    // given
    var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: ["secret"])
    let cases: [(String, String, String?)] = [
      ("web_search", "query secret", "query " + SecretRedactor.replacement),
      (
        "web_fetch",
        "https://user:password@example.org/secret?q=secret#fragment",
        "example.org/" + SecretRedactor.replacement
      ),
      ("web_fetch", "example.org", "example.org"),
      ("skill_load", "skill secret", "skill " + SecretRedactor.replacement),
      ("file_read", "folder/file.txt", "folder/file.txt"),
      ("file_write", "../private.txt", nil),
      ("file_read", "/private.txt", nil),
      ("file_read", "folder/../private.txt", nil),
      ("memory_write", "private contents", nil),
      ("execute_code", "private code", nil),
      (CoderToolNames.submit, "private task", nil),
      (CoderToolNames.status, "private job", nil),
      (CoderToolNames.cancel, "private job", nil),
      ("mcp__server__remote", "private arguments", nil),
      ("registered_other", "private arguments", nil),
    ]

    // when
    for (index, entry) in cases.enumerated() {
      state.apply(
        .toolStarted(
          id: TurnToolStepID(providerCallID: "round", toolCallID: "\(index)"),
          tool: tool(entry.0),
          preview: entry.1
        )
      )
    }
    let steps = state.snapshot(elapsedSeconds: 0).steps

    // then
    try #require(steps.count == cases.count)
    for (index, entry) in cases.enumerated() {
      #expect(steps[index].preview == entry.2)
    }
    let mcp = try #require(
      steps.first {
        $0.label.contains("mcp__")
      }
    )
    #expect(mcp.label.contains("server__remote"))
  }

  @Test
  func unregisteredIdentityFailsClosedAndCoderSuccessMeansSubmitted() throws {
    // given
    var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [])
    let unknown = TurnToolStepID(providerCallID: "round", toolCallID: "unknown")
    let coder = TurnToolStepID(providerCallID: "round", toolCallID: "coder")
    let registered = TurnToolStepID(providerCallID: "round", toolCallID: "registered")

    // when
    state.apply(.toolStarted(id: unknown, tool: nil, preview: "model identity"))
    state.apply(.toolState(id: unknown, state: .succeeded))
    state.apply(.toolStarted(id: coder, tool: tool(CoderToolNames.submit), preview: "task"))
    state.apply(.toolState(id: coder, state: .succeeded))
    state.apply(.toolStarted(id: registered, tool: tool("Unknown tool"), preview: nil))
    state.apply(.toolState(id: registered, state: .succeeded))
    let steps = state.snapshot(elapsedSeconds: 0).steps

    // then
    let failed = try #require(
      steps.first {
        $0.id == unknown
      }
    )
    let submitted = try #require(
      steps.first {
        $0.id == coder
      }
    )
    #expect(
      steps.first {
        $0.id == registered
      }?.state == .succeeded
    )
    #expect(failed.state == .failed)
    #expect(failed.preview == nil)
    #expect(failed.label.contains("model identity") == false)
    #expect(submitted.label.lowercased().contains("submitted"))
    #expect(submitted.label.lowercased().contains("finished") == false)
  }

  @Test
  func toolTransitionsClearInterimAnswerAndKeepRoundIdentitiesSeparate() {
    // given
    var state = TurnProgressState(showsProgress: true, resumed: true, secretValues: [])
    #expect(state.snapshot(elapsedSeconds: 0).phase == .resumed)
    let first = TurnToolStepID(providerCallID: "first", toolCallID: "same")
    let second = TurnToolStepID(providerCallID: "second", toolCallID: "same")

    // when
    state.apply(.toolStarted(id: first, tool: tool("web_search"), preview: "first"))
    state.apply(.answerPreview("interim"))
    state.apply(.modelStarted(providerCallID: "second"))
    state.apply(.toolStarted(id: second, tool: tool("web_search"), preview: "second"))
    state.apply(.waitingForApproval(id: second))
    let waiting = state.snapshot(elapsedSeconds: 10)
    state.apply(.toolState(id: second, state: .executing))
    let executing = state.snapshot(elapsedSeconds: 11)

    // then
    #expect(waiting.answerPreview.isEmpty)
    #expect(waiting.phase == .approval)
    #expect(waiting.steps.count == 2)
    #expect(waiting.steps.first?.state == .pending)
    #expect(executing.phase == .tool)
    #expect(executing.steps.last?.state == .executing)
  }

  @Test
  func displayInputsAreCappedWithoutRetainingRawPayloads() {
    // given
    var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [])
    let long = String(repeating: "👩🏽‍💻", count: TelegramMessageLimits.maxRichMessageCharacters + 1)

    // when
    state.apply(
      .toolStarted(
        id: TurnToolStepID(providerCallID: "round", toolCallID: "query"),
        tool: tool("web_search"),
        preview: long
      )
    )
    state.apply(
      .toolStarted(
        id: TurnToolStepID(providerCallID: "round", toolCallID: "identity"),
        tool: tool(long),
        preview: "omitted"
      )
    )
    state.apply(.answerPreview(long))
    let snapshot = state.snapshot(elapsedSeconds: -1)

    // then
    #expect(snapshot.steps.first?.preview?.count == TurnProgressLimits.previewCharacters)
    #expect(snapshot.steps.last?.label.count == TurnProgressLimits.previewCharacters)
    #expect(snapshot.answerPreview.count == TelegramMessageLimits.maxRichMessageCharacters)
    #expect(snapshot.elapsedSeconds == 0)
  }
}

// MARK: - Fixtures

private extension TurnProgressStateTests {
  func tool(_ name: String) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: "",
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe
    )
  }

  func explanation(_ text: LLMProgressText) -> LLMProgressEvent {
    LLMProgressEvent(itemID: "item", kind: .summary, text: text)
  }
}
