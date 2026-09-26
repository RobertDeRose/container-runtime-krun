import ContainerResource
import ContainerizationError
import Foundation
import KrunVMMProtocol
import Logging

#if canImport(Darwin)
  import Darwin
#endif

/// Runtime network selection. The vmnet-helper mode exists only to benchmark
/// the same Apple-kernel/vminitd VM against the pre-native Unixgram datapath.
public enum KrunNetworkBackendMode: Sendable, Equatable {
  case nativeVMNet
  case vmnetHelperControl
}

public final class KrunVMNetBackend: @unchecked Sendable {
  public let networkConfig: KrunNetworkConfig

  private let stopBackend: () -> Void

  private init(
    networkConfig: KrunNetworkConfig,
    stopBackend: @escaping () -> Void = {}
  ) {
    self.networkConfig = networkConfig
    self.stopBackend = stopBackend
  }

  public static func start(
    attachment: Attachment,
    index: Int,
    mode: KrunNetworkBackendMode,
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
      guard attachment.variant == "allocationOnly" else {
        if attachment.variant == "reserved" {
          throw ContainerizationError(
            .unsupported,
            message:
              "network \(attachment.network) is incompatible with container-runtime-krun; "
              + "use container-network-vmnet with variant=allocationOnly"
          )
        }
        throw KrunFeatureGate.unsupported(
          "network variant \(attachment.variant ?? "unknown")"
        )
      }

      switch mode {
      case .nativeVMNet:
        return KrunVMNetBackend(
          networkConfig: KrunNetworkConfig(
            backend: .nativeVMNetShared,
            ipv4Gateway: attachment.ipv4Gateway.description,
            ipv4Mask: ipv4String(attachment.ipv4Address.prefix.prefixMask32),
            macAddress: macAddress.bytes,
            features: KrunNetworkFeatures.nativeVMNetTCPOffload
          )
        )
      case .vmnetHelperControl:
        return try await startVMNetHelperControl(
          attachment: attachment,
          macAddress: macAddress.bytes,
          index: index,
          logPath: logPath,
          lifecycleStartedAt: lifecycleStartedAt,
          log: log
        )
      }
    #endif
  }

  public func stop() {
    stopBackend()
  }

  #if os(macOS)
    @available(macOS 26, *)
    private static func startVMNetHelperControl(
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
        "--enable-tso",
        "--enable-checksum-offload",
        "--start-address", attachment.ipv4Gateway.description,
        "--end-address", ipv4String(attachment.ipv4Address.upper.value - 1),
        "--subnet-mask", ipv4String(attachment.ipv4Address.prefix.prefixMask32),
      ]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = logHandle
      process.standardError = logHandle

      do {
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "vmnet-helper control launch",
          metadata: ["network_index": "\(index)"]
        )
        try process.run()
        try await waitUntilReady(process: process, socketPath: socketPath, logPath: logPath)
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "vmnet-helper control ready",
          metadata: [
            "network_index": "\(index)",
            "pid": "\(process.processIdentifier)",
            "socket": "\(socketPath)",
          ]
        )
        return KrunVMNetBackend(
          networkConfig: KrunNetworkConfig(
            backend: .unixgram,
            ipv4Gateway: attachment.ipv4Gateway.description,
            ipv4Mask: ipv4String(attachment.ipv4Address.prefix.prefixMask32),
            socketPath: socketPath,
            macAddress: macAddress,
            features: KrunNetworkFeatures.nativeVMNetTCPOffload
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
    for candidate in [
      "/opt/homebrew/opt/vmnet-helper/libexec/vmnet-helper",
      "/usr/local/opt/vmnet-helper/libexec/vmnet-helper",
      "/opt/vmnet-helper/bin/vmnet-helper",
    ] where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    throw ContainerizationError(
      .notFound,
      message: "vmnet-helper control requires vmnet-helper to be installed"
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
      message: "vmnet-helper did not create \(socketPath) within 30 seconds; helper log: \(contents)"
    )
  }

  private static func ipv4String(_ value: UInt32) -> String {
    [24, 16, 8, 0].map { String((value >> $0) & 0xff) }.joined(separator: ".")
  }

  private static func terminate(_ process: Foundation.Process) {
    guard process.isRunning else { return }
    process.terminate()
    for _ in 0..<100 where process.isRunning {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      #if canImport(Darwin)
        kill(process.processIdentifier, SIGKILL)
      #endif
    }
    process.waitUntilExit()
  }
}
