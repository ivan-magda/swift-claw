import Foundation

// MARK: - Chat contract

/// One message in an OpenAI-compatible chat exchange. Reuses `MessageRole`
/// (system/user/assistant) so the persisted role and the wire role share one vocabulary.
public struct ChatMessage: Sendable, Equatable {
  public let role: MessageRole
  public let content: String

  public init(role: MessageRole, content: String) {
    self.role = role
    self.content = content
  }
}

/// A blocking chat-completions request.
public struct ChatRequest: Sendable, Equatable {
  public let model: String
  public let messages: [ChatMessage]
  public let maxOutputTokens: Int
  // swiftlint:disable:next discouraged_optional_collection
  public let stop: [String]?

  public init(
    model: String,
    messages: [ChatMessage],
    maxOutputTokens: Int,
    // swiftlint:disable:next discouraged_optional_collection
    stop: [String]? = nil
  ) {
    self.model = model
    self.messages = messages
    self.maxOutputTokens = maxOutputTokens
    self.stop = stop
  }
}

/// Token accounting returned by the provider. An omitted `usage` is a nil `ChatResponse.usage`,
/// not this; `.zero` is a genuine zero count.
public struct ChatUsage: Sendable, Equatable {
  public let promptTokens: Int
  public let completionTokens: Int
  public let totalTokens: Int

  public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }

  public static let zero = ChatUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
}

/// A parsed assistant reply. `content` is never nil (null content → ""); `usage` is nil when the
/// provider omits accounting (some local servers do); `costFromProvider` is set only when the
/// provider reports cost (OpenRouter `usage.cost` / LiteLLM header).
public struct ChatResponse: Sendable, Equatable {
  public let content: String
  public let finishReason: String?
  public let usage: ChatUsage?
  public let costFromProvider: Double?

  public init(
    content: String,
    finishReason: String?,
    usage: ChatUsage?,
    costFromProvider: Double?
  ) {
    self.content = content
    self.finishReason = finishReason
    self.usage = usage
    self.costFromProvider = costFromProvider
  }
}

/// The single provider seam: one blocking round-trip. The concrete impl lives in `ClawLLM`.
public protocol LLMProvider: Sendable {
  func complete(request: ChatRequest) async throws -> ChatResponse
}

/// Provider failures tagged for the retry classifier and the degradation UX.
/// retryable = 408 / 429 / 5xx (incl. 529) / transport; terminal = 400 / 401 / 403 / 404 / 413 / 422.
public enum ProviderError: Error, Sendable, Equatable {
  case retryable(status: Int?, message: String)
  case terminal(status: Int?, message: String)
}

// MARK: - Configuration

/// Which JSON key carries the output cap. Default `max_completion_tokens`; older local
/// servers need `max_tokens` (F17), switchable via `CLAW_LLM_MAX_TOKENS_FIELD`.
public enum MaxTokensField: String, Sendable, Equatable {
  case maxCompletionTokens = "max_completion_tokens"
  case maxTokens = "max_tokens"
}

/// Static LLM wiring loaded from the environment. `apiKey` defaults to "" — local servers
/// need none, so a missing key is not a config error.
public struct LLMConfig: Sendable, Equatable {
  public let baseURL: String
  public let model: String
  public let apiKey: String
  public let maxTokensField: MaxTokensField
  public let maxOutputTokens: Int
  public let retryBudget: Int
  public let requestTimeoutSeconds: Int

  public init(
    baseURL: String,
    model: String,
    apiKey: String,
    maxTokensField: MaxTokensField,
    maxOutputTokens: Int,
    retryBudget: Int,
    requestTimeoutSeconds: Int
  ) {
    self.baseURL = baseURL
    self.model = model
    self.apiKey = apiKey
    self.maxTokensField = maxTokensField
    self.maxOutputTokens = maxOutputTokens
    self.retryBudget = retryBudget
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }
}

extension LLMConfig {
  /// Returns a copy with the runtime secret injected. `AppConfig` carries no key (it's a secret);
  /// the composition root combines the non-secret LLM config with `Secrets.llmApiKey`.
  public func withAPIKey(_ apiKey: String) -> LLMConfig {
    LLMConfig(
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      maxTokensField: maxTokensField,
      maxOutputTokens: maxOutputTokens,
      retryBudget: retryBudget,
      requestTimeoutSeconds: requestTimeoutSeconds
    )
  }
}

// MARK: - Pricing

/// Per-million-token USD prices for one model — the normalized `Prices.json` schema.
public struct ModelPrice: Sendable, Equatable, Codable {
  public let inputUSDPerMTok: Double
  public let outputUSDPerMTok: Double

  public init(inputUSDPerMTok: Double, outputUSDPerMTok: Double) {
    self.inputUSDPerMTok = inputUSDPerMTok
    self.outputUSDPerMTok = outputUSDPerMTok
  }
}

/// The vendored offline price snapshot. `.empty` is the safe fallback when the resource is
/// absent/unreadable — the heuristic tier then carries USD.
public struct PriceTable: Sendable, Equatable {
  public let prices: [String: ModelPrice]

  public init(prices: [String: ModelPrice]) {
    self.prices = prices
  }

  public func price(for model: String) -> ModelPrice? {
    prices[model]
  }

  public static let empty = PriceTable(prices: [:])
}

// MARK: - Token estimation

/// Offline, conservative token estimation in the **token domain** (distinct from the §9
/// grapheme-domain assembly cap). A double-ceil of `graphemes / 4 * 1.25` rounds the estimate
/// up at each step; `graphemeBudget` is its inverse (rounds down) for the §9 assembly cap.
public enum TokenEstimator {
  /// Estimated input tokens, summed per message so each message's rounding adds headroom.
  public static func estimateInputTokens(_ messages: [ChatMessage]) -> Int {
    messages.reduce(0) { running, message in
      running + estimateTokens(forText: message.content)
    }
  }

  /// Estimated tokens for a single text body — used to account for an assistant reply when the
  /// provider returned no usage.
  public static func estimateTokens(forText text: String) -> Int {
    inputTokens(forGraphemes: text.count)
  }

  /// Estimated input tokens plus the reserved output cap.
  public static func estimateTotalTokens(_ messages: [ChatMessage], maxOutput: Int) -> Int {
    estimateInputTokens(messages) + maxOutput
  }

  /// Inverse of input-token estimation: the max graphemes that fit a token budget (§9 cap).
  public static func graphemeBudget(forInputTokens inputTokens: Int) -> Int {
    Int(floor(Double(inputTokens) / 1.25)) * 4
  }

  private static func inputTokens(forGraphemes graphemes: Int) -> Int {
    Int(ceil(ceil(Double(graphemes) / 4) * 1.25))
  }
}

// MARK: - Cost resolution

/// The result of `CostResolver.resolve`: the cost, its source tier, and whether it's an estimate.
public struct ResolvedCost: Sendable, Equatable {
  public let costUSD: Double
  public let source: CostSource
  public let isEstimated: Bool

  public init(costUSD: Double, source: CostSource, isEstimated: Bool) {
    self.costUSD = costUSD
    self.source = source
    self.isEstimated = isEstimated
  }
}

/// Best-effort USD cost — never a silent $0 (D1 / F19). The first known source wins:
/// provider-returned (incl. a confirmed $0) → vendored price-file (incl. a free model's $0) →
/// reference-rate heuristic. Only the heuristic is `isEstimated`, and only it is floored at
/// `heuristicFloorUSD`, so a *guessed* cost is never recorded as $0.
public struct CostResolver: Sendable {
  /// The never-silent-$0 floor for a heuristic tier that computes to 0.
  public static let heuristicFloorUSD = 0.000_001

  public let priceTable: PriceTable
  public let referenceUSDPerToken: Double

  public init(priceTable: PriceTable, referenceUSDPerToken: Double) {
    self.priceTable = priceTable
    self.referenceUSDPerToken = referenceUSDPerToken
  }

  public func resolve(
    model: String,
    usage: ChatUsage,
    providerCost: Double?
  ) -> ResolvedCost {
    if let providerCost {
      return ResolvedCost(costUSD: providerCost, source: .providerReturned, isEstimated: false)
    }

    if let price = priceTable.price(for: model) {
      let cost =
        Double(usage.promptTokens) / 1_000_000 * price.inputUSDPerMTok
        + Double(usage.completionTokens) / 1_000_000 * price.outputUSDPerMTok
      return ResolvedCost(costUSD: cost, source: .priceFile, isEstimated: false)
    }

    let raw = Double(usage.totalTokens) * referenceUSDPerToken
    let cost = raw == 0 ? Self.heuristicFloorUSD : raw
    return ResolvedCost(costUSD: cost, source: .heuristic, isEstimated: true)
  }
}

// MARK: - Usage resolution

/// The token usage to record, plus whether those counts are an estimate. Peer to `ResolvedCost`:
/// `isEstimated` here is the verdict on the *tokens* alone; cost estimation is `CostResolver`'s.
public struct ResolvedUsage: Sendable, Equatable {
  public let usage: ChatUsage
  public let isEstimated: Bool

  public init(usage: ChatUsage, isEstimated: Bool) {
    self.usage = usage
    self.isEstimated = isEstimated
  }
}

/// Reconciles the token counts to record. Peer to `CostResolver` (counts vs. price): provider-
/// returned usage is truth; a provider that omits it (some local servers do) is estimated rather
/// than recorded as zero, so the hard daily token breaker (§5.3) can still account for the call.
public struct UsageResolver: Sendable {
  public init() {}

  /// Provider-returned usage wins; when the response omits it, estimate prompt from the sent
  /// `context` and completion from the returned `response.content`.
  public func resolve(response: ChatResponse, context: [ChatMessage]) -> ResolvedUsage {
    if let reported = response.usage {
      return ResolvedUsage(usage: reported, isEstimated: false)
    }
    return estimated(
      promptTokens: TokenEstimator.estimateInputTokens(context),
      completionTokens: TokenEstimator.estimateTokens(forText: response.content)
    )
  }

  /// The estimate for a call that produced no response (deadline / exhausted retries): prompt from
  /// `context`, completion reserved at the output cap since no reply exists to measure.
  public func estimate(context: [ChatMessage], maxOutputTokens: Int) -> ResolvedUsage {
    estimated(
      promptTokens: TokenEstimator.estimateInputTokens(context),
      completionTokens: maxOutputTokens
    )
  }

  private func estimated(promptTokens: Int, completionTokens: Int) -> ResolvedUsage {
    ResolvedUsage(
      usage: ChatUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: promptTokens + completionTokens
      ),
      isEstimated: true
    )
  }
}
