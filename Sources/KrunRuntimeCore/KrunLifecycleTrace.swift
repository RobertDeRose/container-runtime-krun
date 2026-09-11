import Logging

/// Lightweight monotonic lifecycle tracing used while validating runtime startup.
///
/// All events for one container use the same `ContinuousClock` origin so logs can
/// be compared directly without relying on wall-clock timestamps.
enum KrunLifecycleTrace {
  static func mark(
    _ log: Logger,
    startedAt: ContinuousClock.Instant,
    event: String,
    metadata extraMetadata: Logger.Metadata = [:]
  ) {
    var metadata = extraMetadata
    metadata["event"] = "\(event)"
    metadata["elapsed_ms"] = "\(elapsedMilliseconds(since: startedAt))"
    log.info("runtime lifecycle", metadata: metadata)
  }

  private static func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Int64 {
    let components = startedAt.duration(to: ContinuousClock.now).components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
  }
}
