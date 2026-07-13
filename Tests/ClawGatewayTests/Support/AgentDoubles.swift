import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation

// MARK: - Context collaborators

/// A `ContextBuilder` over the empty collaborators: assembles the trigger-bounded history with no
/// workspace files, memory items, or recall hits — enough to drive `TurnRunner` end to end.
func makeEmptyContextBuilder() -> ContextBuilder {
  ContextBuilder(
    systemPrompt: SystemPrompt.minimal,
    workspace: EmptyWorkspace(),
    memoryStore: EmptyMemoryStore(),
    retriever: EmptyRetriever(),
    budget: .default,
    now: { Date(timeIntervalSince1970: 0) }
  )
}
