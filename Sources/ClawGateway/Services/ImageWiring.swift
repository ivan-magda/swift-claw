/// The one entry point that connects the two ends of the inbound-image path: the router that
/// deposits a photo's bytes and the runner that replays them. It mints the cache itself, so a
/// composition root cannot hand the two ends different caches — the failure that would store every
/// photo, replay none, and leave every test green.
public enum ImageWiring {
  /// Wires one cache into both ends and returns them.
  ///
  /// The router arrives as a factory rather than a built value because `MessageRouter` copies the
  /// `TurnRunner` it dispatches through: a router built before the runner is wired would enqueue the
  /// unwired copy and replay nothing. Building the router from the wired runner is the only order
  /// that works, so it is the only order this signature can express.
  ///
  /// The returned runner is the wired one — hand it to every other consumer (scheduler, approvals)
  /// so a proactive run replays the same images an interactive one does.
  public static func wire(
    runner: TurnRunner,
    router makeRouter: (TurnRunner) -> MessageRouter
  ) -> (router: MessageRouter, runner: TurnRunner) {
    let cache = ImageCache()
    let wiredRunner = runner.withImageCache(cache)
    return (makeRouter(wiredRunner).withImageCache(cache), wiredRunner)
  }
}
