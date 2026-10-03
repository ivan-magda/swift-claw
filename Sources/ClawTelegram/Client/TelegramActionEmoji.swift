import ClawCore

/// Action icons from https://t.me/addemoji/AIActions, verified via getStickerSet on 2026-10-03.
/// The pack marks these animated icons needs_repainting, so clients can match the text color.
enum TelegramActionEmoji: String, CaseIterable {
  case thinking = "5535457114983497745"
  case search = "5535248817659576336"
  case readPage = "5535365052359507996"
  case readFile = "5535039193190760468"
  case writeFile = "5537203062138994712"
  case memory = "5535151270362349597"
  case loadSkill = "5537230721728380949"
  case executeCode = "5535251334510411788"
  case coding = "5537247356136718385"
  case approval = "5537353471893700616"
  case working = "5537515087218081814"
  case answer = "5573451671289200650"

  var statusLabel: String {
    switch self {
    case .thinking:
      "Thinking"
    case .search:
      "Searching"
    case .readPage, .readFile:
      "Reading"
    case .writeFile:
      "Writing"
    case .memory:
      "Updating memory"
    case .loadSkill:
      "Loading skill"
    case .executeCode:
      "Running code"
    case .coding:
      "Submitting coding job"
    case .approval:
      "Waiting for your approval"
    case .working:
      "Working"
    case .answer:
      "Progress"
    }
  }

  var fallback: String {
    switch self {
    case .thinking, .memory:
      "🧠"
    case .search:
      "🔎"
    case .readPage:
      "🌐"
    case .readFile, .loadSkill:
      "📄"
    case .writeFile:
      "✍️"
    case .executeCode, .coding:
      "💻"
    case .approval:
      "🤔"
    case .working:
      "⚙️"
    case .answer:
      "✨"
    }
  }

  var markup: String {
    "<tg-emoji emoji-id=\"\(rawValue)\">\(fallback)</tg-emoji>"
  }

  init(snapshot: TurnProgressSnapshot) {
    if !snapshot.answerPreview.isEmpty {
      self = .answer
      return
    }

    switch snapshot.phase {
    case .model:
      self = .thinking
    case .approval:
      self = .approval
    case .answer:
      self = .answer
    case .preparing, .resumed:
      self = .working
    case .tool:
      let activeStep = snapshot.steps.last { step in
        step.state == .executing || step.state == .pending
      }
      self.init(action: activeStep?.action ?? .tool)
    }
  }

  /// Only replace a known, owned heading prefix. Answer markup and tool text are left intact.
  static func replacingHeading(in markdown: String) -> String {
    for emoji in allCases {
      let prefix = "<tg-thinking>\(emoji.markup) "

      if markdown.hasPrefix(prefix) {
        return "<tg-thinking>\(emoji.fallback) \(markdown.dropFirst(prefix.count))"
      }
    }

    return markdown
  }
}

// MARK: - Tool Actions

private extension TelegramActionEmoji {
  init(action: TurnToolAction) {
    switch action {
    case .tool:
      self = .working
    case .search:
      self = .search
    case .readPage:
      self = .readPage
    case .readFile:
      self = .readFile
    case .writeFile:
      self = .writeFile
    case .memory:
      self = .memory
    case .loadSkill:
      self = .loadSkill
    case .executeCode:
      self = .executeCode
    case .coding:
      self = .coding
    }
  }
}
