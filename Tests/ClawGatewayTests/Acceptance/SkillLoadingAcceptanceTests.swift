import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import ClawTools
import Foundation
import Testing

@testable import ClawGateway

/// Workspace skills, end to end over the real router → lane → TurnRunner → tool stack: the owner
/// drops one `SKILL.md` into the workspace, the index reaches the model under the `skills` fence,
/// the model names the skill, and the body comes back under the SAME fence without tainting the
/// session — so the next turn still recalls high-sensitivity memory.
@Suite(.serialized) struct SkillLoadingAcceptanceTests {
  private static let manifest = """
    ---
    name: summarize
    description: Summarize owner-provided text.
    ---
    # Summarize

    Keep it to three bullets.
    """

  private static let skillCall = ToolCall(
    id: "s1",
    name: "skill_load",
    argumentsJSON: #"{"name":"summarize"}"#
  )

  // swiftlint:disable:next function_body_length
  @Test func skillIsIndexedLoadedUnderTheSkillsFenceWithoutTaint() async throws {
    // given — one installed skill on disk and one high-sensitivity fact the taint guard would
    // suppress if loading a skill counted as ingesting untrusted content
    let harness = try makeSC3Harness(
      scripts: [
        [toolCallResponse([Self.skillCall]), okResponse(content: "Three bullets, as instructed.")],
        [okResponse(content: "Still with you.")],
      ],
      httpResponses: [:],
      workspaceFiles: ["skills/summarize/SKILL.md": Self.manifest]
    )
    _ = try harness.stores.memory.append(
      NewMemoryItem(text: "vault code omega", kind: .user, sensitivity: .high, sessionId: nil),
      now: Date(timeIntervalSince1970: 86_400)
    )

    // when — the owner sends a message the skill covers
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "summarize this thread")
    )
    _ = try await harness.waitForOutbox(atLeast: 1)

    // then — the index reached the model under the `skills` fence, naming the skill and no path
    let requests = await harness.provider.requests
    let indexRequest = try #require(requests.first)
    let index = try #require(
      indexRequest.messages.first { message in
        message.role == .user && message.content.text.contains("label=\"skills\"")
      }
    ).content.text
    #expect(index.contains("- summarize: Summarize owner-provided text."))
    #expect(index.contains(harness.workspaceRoot.path) == false)

    // then — the loaded body came back fenced as `skills`, not as the tool's own name, stripped of
    // its frontmatter and carrying the untrusted fence the prompt's carve-out is written against
    let loadRequest = try #require(requests.dropFirst().first)
    let observation = try #require(
      loadRequest.messages.first { message in message.role == .tool }
    ).content.text
    #expect(observation.contains("label=\"skills\""))
    #expect(observation.contains("label=\"skill_load\"") == false)
    #expect(observation.contains("<claw-untrusted nonce="))
    #expect(observation.contains("Keep it to three bullets."))
    #expect(observation.contains("name: summarize") == false)

    // then — loading a skill did not taint the session
    #expect(try harness.snapshot().isTainted == false)

    // when — a second turn runs in the same session
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "and now?"))
    _ = try await harness.waitForOutbox(atLeast: 2)

    // then — high-sensitivity recall is still injected, and the replayed tool row keeps the label
    let nextRequest = try #require(await harness.provider.requests.last)
    let recall = try #require(
      nextRequest.messages.first { message in
        message.content.text.contains("label=\"memory_items\"")
      }
    ).content.text
    #expect(recall.contains("vault code omega"))
    let replayed = try #require(nextRequest.messages.first { message in message.role == .tool })
      .content.text
    #expect(replayed.contains("label=\"skills\""))
    #expect(replayed.contains("Keep it to three bullets."))
  }

  /// The model names a skill; it never types a path. A path-shaped argument resolves against the
  /// scan like any other name — it misses, and the miss is the self-correcting list of real names.
  @Test func aPathShapedNameNeverEscapesTheSkillsDirectory() async throws {
    // given — a secret file one level above the skills directory
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "s1",
              name: "skill_load",
              argumentsJSON: #"{"name":"../../secret"}"#
            )
          ]),
          okResponse(content: "I only have the summarize skill."),
        ]
      ],
      httpResponses: [:],
      workspaceFiles: [
        "skills/summarize/SKILL.md": Self.manifest,
        "secret.md": "TOP SECRET WORKSPACE CONTENT",
      ]
    )

    // when
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "use a skill"))
    _ = try await harness.waitForOutbox(atLeast: 1)

    // then — the miss lists the installed names, and nothing outside the skill body is served
    let requests = await harness.provider.requests
    let loadRequest = try #require(requests.dropFirst().first)
    let observation = try #require(
      loadRequest.messages.first { message in message.role == .tool }
    ).content.text
    #expect(observation.contains("Installed skills: summarize"))
    #expect(
      requests.allSatisfy { request in
        request.messages.allSatisfy { message in
          message.content.text.contains("TOP SECRET WORKSPACE CONTENT") == false
        }
      }
    )
  }
}
