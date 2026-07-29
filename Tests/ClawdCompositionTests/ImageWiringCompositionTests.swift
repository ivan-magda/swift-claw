import AsyncHTTPClient
import ClawAgent
import ClawData
import ClawLLM
import ClawSecrets
import ClawTelegram
import ClawWorkspace
import Foundation
import Logging
import Testing

// swift-format sorts imports by ASCII, SwiftLint case-insensitively, and `ClawGateway`/`clawd`
// is the pair the two never agree on.
// swiftlint:disable sorted_imports
@testable import ClawCore
@testable import ClawGateway
@testable import clawd

// swiftlint:enable sorted_imports

/// Drives the production composition root's runner fan-out and proves the wiring the whole inbound
/// image feature rests on: `MessageRouter`, `ApprovalWaiter`, and `SchedulerService` each COPY the
/// `TurnRunner` value, so a consumer built from a copy taken before the intake wiring holds no image
/// cache — it would replay nothing, quietly, with every other test still green.
@Suite struct ImageWiringCompositionTests {
  private static let botToken = "test-token"
  private static let ownerChatId: Int64 = 42
  private static let filePath = "photos/file_1.jpg"
  /// The shortest body `ImageMediaType.sniff` accepts as a JPEG.
  private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

  private static let photoWidth = 1280
  private static let photoHeight = 960

  private var expectedImage: ImagePart {
    ImagePart(
      data: Self.jpeg,
      mediaType: .jpeg,
      width: Self.photoWidth,
      height: Self.photoHeight
    )
  }

  @Test func optingOutLeavesABarePhotoClosedWithTheCannedReply() async throws {
    // given — the same fan-out with CLAW_IMAGE_INPUT=false, and nothing but the photo
    let root = try makeRoot(imageInput: "false")
    let consumers = try await makeConsumers(root: root)
    root.coordination.lanes.closeAdmission()

    // when
    let outcome = await consumers.poller.router.handle(rawUpdate: photoUpdate(caption: nil))

    // then — no service means no download and no turn, just the pre-feature reply
    #expect(outcome == .processed)
    let sent = await root.telegram.recorded.map(\.url)
    #expect(sent == ["https://api.telegram.org/bot\(Self.botToken)/sendMessage"])
    let body = try #require(String(bytes: await root.telegram.lastBody ?? Data(), encoding: .utf8))
    #expect(
      body.contains(
        MessageRouter.unsupportedMediaText(kind: PhotoAttachment.mediaKindDescription)
      )
    )
  }
}

// MARK: - Fixtures

private extension ImageWiringCompositionTests {
  /// The cross-cutting inputs the composition root resolves before wiring, held together so a test
  /// can reach the stores and lanes the built graph shares.
  struct CompositionRoot {
    let config: AppConfig
    let stores: ClawStores
    let telegram: AcceptanceStreamingHTTP
    let coordination: DaemonBuilder.TurnCoordination
    let builder: DaemonBuilder
  }

  func makeRoot(imageInput: String? = nil) throws -> CompositionRoot {
    var environment = [
      AppConfig.EnvKey.stateRoot: NSTemporaryDirectory() + "clawd-image-" + UUID().uuidString,
      AppConfig.EnvKey.llmModel: "gpt-4o",
      AppConfig.EnvKey.llmBaseURL: "https://api.test/v1",
    ]
    environment[AppConfig.EnvKey.imageInput] = imageInput

    let config = try AppConfig.load(environment: environment)
    let stores = try EnvironmentLoader.openStores(config: config)
    try stores.allowlist.seedAllowlist(userIds: [Self.ownerChatId])

    let telegram = makeTelegramHTTP()
    return CompositionRoot(
      config: config,
      stores: stores,
      telegram: telegram,
      coordination: DaemonBuilder.TurnCoordination(),
      builder: DaemonBuilder(
        config: config,
        secrets: Secrets(
          telegramBotToken: Self.botToken,
          llmApiKey: "sk-static",
          searchApiKey: nil
        ),
        stores: stores,
        // The singleton client is never shut down by design, so a failing expectation cannot leak
        // one; nothing in this suite ever submits a request through it.
        toolExecutor: AsyncHTTPExecutor(client: .shared),
        transport: TelegramClient(token: Self.botToken, http: telegram),
        botUsername: nil,
        logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() }),
        makeManagedStore: { FreshCredentialStore(present: false) }
      )
    )
  }

  func makeConsumers(root: CompositionRoot) async throws -> DaemonBuilder.RunnerConsumers {
    let providerStack = try root.builder.makeProviderStack(
      http: AsyncHTTPExecutor(client: .shared)
    )
    let costResolver = CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: root.config.budget.referenceUSDPerToken
    )
    let workspace = FileSystemWorkspace(
      root: EnvironmentLoader.workspaceRoot(config: root.config)
    )
    let sandbox = await root.builder.prepareSandbox()

    return root.builder.makeRunnerConsumers(
      coordination: root.coordination,
      agentStack: root.builder.makeAgentStack(
        providerStack: providerStack,
        workspace: workspace,
        costResolver: costResolver,
        sandbox: sandbox
      ),
      providerStack: providerStack,
      costResolver: costResolver,
      workspace: workspace,
      sandbox: sandbox
    )
  }

  /// Answers exactly the calls an inbound photo makes — `getFile`, the bounded file GET, and the
  /// canned reply's `sendMessage`. Anything else throws, so a stray production call is loud.
  func makeTelegramHTTP() -> AcceptanceStreamingHTTP {
    let base = "https://api.telegram.org"
    let getFile = #"{"ok":true,"result":{"file_id":"photo-1","file_path":"\#(Self.filePath)"}}"#
    let sent = #"{"ok":true,"result":{"message_id":7,"chat":{"id":\#(Self.ownerChatId)}}}"#

    return AcceptanceStreamingHTTP(
      streamScripts: [],
      bufferedResponses: [
        "\(base)/bot\(Self.botToken)/getFile": HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Data(getFile.utf8)
        ),
        "\(base)/file/bot\(Self.botToken)/\(Self.filePath)": HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Self.jpeg
        ),
        "\(base)/bot\(Self.botToken)/sendMessage": HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Data(sent.utf8)
        ),
      ]
    )
  }

  func photoUpdate(caption: String? = "Что это?") -> RawUpdate {
    RawUpdate(
      updateId: 1,
      message: RawMessage(
        messageId: 1,
        fromUserId: Self.ownerChatId,
        chatId: Self.ownerChatId,
        text: nil,
        caption: caption,
        mediaKind: PhotoAttachment.mediaKindDescription,
        photo: PhotoAttachment(sizes: [
          PhotoSize(
            fileId: "photo-1",
            fileUniqueId: "u-1",
            width: Self.photoWidth,
            height: Self.photoHeight,
            fileSizeBytes: 186_422
          )
        ])
      ),
      editedMessage: nil
    )
  }
}
