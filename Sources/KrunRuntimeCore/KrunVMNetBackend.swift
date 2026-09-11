import ContainerResource
import ContainerizationError
import Foundation
import KrunVMMProtocol
import Logging

#if canImport(Darwin)
  import Darwin
#endif
public final class KrunVMNetBackend: @unchecked Sendable {
  public let networkConfig: KrunNetworkConfig

  private let stopBackend: () -> Void

  private init(
    networkConfig: KrunNetworkConfig,
    stopBackend: @escaping () -> Void
  ) {
    self.networkConfig = networkConfig
    self.stopBackend = stopBackend
  }

  public static func start(
    attachment: Attachment,
    index: Int,
    logPath: URL,
    lifecycleStartedAt: ContinuousClock.Instant,
    log: Logger
  ) async throws -> KrunVMNetBackend {
    #if !os(macOS)
      throw KrunFeatureGate.unsupported("networking outside macOS")
    #else
      guard #available(macOS 26, *) else {
        throw KrunFeatureGate.unsupported("networking on macOS versions older than 26")
      }
      guard let macAddress = attachment.macAddress else {
        throw ContainerizationError(
          .invalidState,
          message: "network attachment \(attachment.network) does not have a MAC address"
        )
      }

      switch attachment.variant {
      case "allocationOnly":
        return try await startAllocationOnly(
          attachment: attachment,
          macAddress: macAddress.bytes,
          index: index,
          logPath: logPath,
          lifecycleStartedAt: lifecycleStartedAt,
          log: log
        )
      case "reserved":
        throw ContainerizationError(
          .unsupported,
          message:
            "container-runtime-krun cannot attach to Apple Container's reserved vmnet network; "
            + "macOS requires a process using vmnet_interface_start_with_network to have the same "
            + "executable identity as the process that created the serialized network. Create an "
            + "allocationOnly network with `container network create --subnet <CIDR> --option "
            + "variant=allocationOnly krun` and run with `--network krun`."
        )
      default:
        throw KrunFeatureGate.unsupported(
          "network variant \(attachment.variant ?? "unknown")"
        )
      }
    #endif
  }

  public func stop() {
    stopBackend()
  }

  #if os(macOS)
    @available(macOS 26, *)
    private static func startAllocationOnly(
      attachment: Attachment,
      macAddress: [UInt8],
      index: Int,
      logPath: URL,
      lifecycleStartedAt: ContinuousClock.Instant,
      log: Logger
    ) async throws -> KrunVMNetBackend {
      let helperPath = try resolveHelperPath()
      let directory = try makeDirectory()
      let socketPath = directory.appendingPathComponent("net\(index).sock").path

      FileManager.default.createFile(atPath: logPath.path, contents: nil)
      let logHandle = try FileHandle(forWritingTo: logPath)
      let process = Foundation.Process()
      process.executableURL = URL(fileURLWithPath: helperPath)
      process.arguments = [
        "--socket", socketPath,
        "--operation-mode", "shared",
        "--enable-isolation",
        "--start-address", attachment.ipv4Gateway.description,
        "--end-address", ipv4String(attachment.ipv4Address.upper.value - 1),
        "--subnet-mask", ipv4String(attachment.ipv4Address.prefix.prefixMask32),
      ]
      process.standardOutput = logHandle
      process.standardError = logHandle

      do {
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "vmnet-helper launch",
          metadata: [
            "network": "\(attachment.network)",
            "network_index": "\(index)",
          ]
        )
        try process.run()
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "vmnet-helper launched",
          metadata: [
            "network_index": "\(index)",
            "pid": "\(process.processIdentifier)",
          ]
        )
        try await waitUntilReady(process: process, socketPath: socketPath, logPath: logPath)
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "vmnet-helper socket ready",
          metadata: [
            "network_index": "\(index)",
            "socket": "\(socketPath)",
          ]
        )
        return KrunVMNetBackend(
          networkConfig: .init(
            socketPath: socketPath,
            macAddress: macAddress
          ),
          stopBackend: {
            terminate(process)
            try? logHandle.close()
            try? FileManager.default.removeItem(at: directory)
          }
        )
      } catch {
        terminate(process)
        try? logHandle.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    }

  #endif

  private static func makeDirectory() throws -> URL {
    let directory = URL(
      fileURLWithPath: "/tmp/container-krun-net-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private static func resolveHelperPath() throws -> String {
    if let configured = ProcessInfo.processInfo.environment["VMNET_HELPER"],
      FileManager.default.isExecutableFile(atPath: configured)
    {
      return configured
    }
    for candidate in [
      "/opt/homebrew/opt/vmnet-helper/libexec/vmnet-helper",
      "/usr/local/opt/vmnet-helper/libexec/vmnet-helper",
      "/opt/vmnet-helper/bin/vmnet-helper",
    ] where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    throw ContainerizationError(
      .notFound,
      message:
        "vmnet-helper was not found; install it or set VMNET_HELPER to the executable path"
    )
  }

  private static func waitUntilReady(
    process: Foundation.Process,
    socketPath: String,
    logPath: URL
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    repeat {
      guard process.isRunning else {
        let contents = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        throw ContainerizationError(
          .internalError,
          message: "vmnet-helper exited before its socket was ready: \(contents)"
        )
      }
      if FileManager.default.fileExists(atPath: socketPath) {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    } while ContinuousClock.now < deadline

    let contents = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
    throw ContainerizationError(
      .timeout,
      message:
        "vmnet-helper did not create \(socketPath) within 30 seconds; helper log: \(contents)"
    )
  }

  private static func ipv4String(_ value: UInt32) -> String {
    [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ].map(String.init).joined(separator: ".")
  }

  private static func terminate(_ process: Foundation.Process) {
    guard process.isRunning else { return }
    process.terminate()
    for _ in 0..<20 where process.isRunning {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
  }
}
