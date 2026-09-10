import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import KrunVMMProtocol
import Logging
import NIOPosix

#if canImport(Darwin)
  import Darwin
#endif

public final class KrunVMController: @unchecked Sendable {
  public let id: String
  public let bundle: ContainerResource.Bundle
  public let config: ContainerConfiguration
  public let rootPath: String
  public let socketLayout: KrunSocketLayout
  public let agent: Vminitd

  private let helper: Foundation.Process
  private let group: MultiThreadedEventLoopGroup
  private let log: Logger
  private let helperLogHandle: FileHandle

  private init(
    id: String,
    bundle: ContainerResource.Bundle,
    config: ContainerConfiguration,
    rootPath: String,
    socketLayout: KrunSocketLayout,
    agent: Vminitd,
    helper: Foundation.Process,
    group: MultiThreadedEventLoopGroup,
    log: Logger,
    helperLogHandle: FileHandle
  ) {
    self.id = id
    self.bundle = bundle
    self.config = config
    self.rootPath = rootPath
    self.socketLayout = socketLayout
    self.agent = agent
    self.helper = helper
    self.group = group
    self.log = log
    self.helperLogHandle = helperLogHandle
  }

  public static func boot(
    bundle: ContainerResource.Bundle,
    helperPath: String,
    libkrunPath: String = KrunDefaults.libkrunPath,
    log: Logger
  ) async throws -> KrunVMController {
    #if !os(macOS) || !arch(arm64)
      throw ContainerizationError(
        .unsupported, message: "container-runtime-krun requires Apple Silicon")
    #else
      let config = try bundle.configuration
      try KrunV01FeatureGate.validate(config)
      let kernel = try bundle.kernel
      let initfs = bundle.initialFilesystem
      let rootfs = try bundle.containerRootfs
      try requireExt4Block(initfs, name: "initial filesystem")
      try requireExt4Block(rootfs, name: "container root filesystem")

      guard FileManager.default.isReadableFile(atPath: helperPath) else {
        throw ContainerizationError(
          .notFound, message: "libkrun helper is not readable at \(helperPath)")
      }
      guard FileManager.default.isReadableFile(atPath: libkrunPath) else {
        throw ContainerizationError(.notFound, message: "libkrun is not readable at \(libkrunPath)")
      }

      let layout = KrunSocketLayout(id: config.id)
      try FileManager.default.createDirectory(
        at: layout.directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )

      let cpus = config.resources.cpus + config.resources.cpuOverhead
      guard cpus > 0, cpus <= Int(UInt8.max) else {
        throw ContainerizationError(.invalidArgument, message: "invalid VM CPU count \(cpus)")
      }
      let memoryBytes = config.resources.memoryInBytes + KrunDefaults.memoryOverheadBytes
      let memoryMiB64 = (memoryBytes + 1024 * 1024 - 1) / (1024 * 1024)
      guard memoryMiB64 <= UInt64(UInt32.max) else {
        throw ContainerizationError(.invalidArgument, message: "VM memory exceeds libkrun limit")
      }

      let helperConfig = KrunVMMConfig(
        libkrun: libkrunPath,
        kernel: kernel.path.resolvingSymlinksInPath().path,
        initDisk: initfs.source,
        rootDisk: rootfs.source,
        commandLine: KrunKernelCommandLine.make(kernel: kernel),
        bootLog: bundle.bootlog.path,
        cpus: UInt8(cpus),
        memoryMiB: UInt32(memoryMiB64),
        vsockMappings: layout.mappings
      )
      let helperConfigPath = bundle.filePath(for: "krun-vmm.json")
      try JSONEncoder().encode(helperConfig).write(to: helperConfigPath)

      let helperLogPath = bundle.filePath(for: "krun-vmm.log")
      FileManager.default.createFile(atPath: helperLogPath.path, contents: nil)
      let helperLog = try FileHandle(forWritingTo: helperLogPath)
      let helper = Foundation.Process()
      helper.executableURL = URL(fileURLWithPath: helperPath)
      helper.arguments = [helperConfigPath.path]
      helper.standardOutput = helperLog
      helper.standardError = helperLog
      try helper.run()

      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let agent: Vminitd
      do {
        agent = try await connectAgent(
          socketPath: layout.controlPath,
          helper: helper,
          helperLogPath: helperLogPath,
          group: group
        )
        try await agent.standardSetup()
        let sysctls = KrunSpecBuilder.guestSysctls(config)
        if !sysctls.isEmpty {
          try await agent.sysctl(settings: sysctls)
        }
        let rootPath = KrunSpecBuilder.guestRootPath(containerID: config.id)
        try await agent.mkdir(path: rootPath, all: true, perms: 0o755)
        try await agent.mount(
          ContainerizationOCI.Mount(
            type: "ext4",
            source: "/dev/vdb",
            destination: rootPath
          )
        )
        return KrunVMController(
          id: config.id,
          bundle: bundle,
          config: config,
          rootPath: rootPath,
          socketLayout: layout,
          agent: agent,
          helper: helper,
          group: group,
          log: log,
          helperLogHandle: helperLog
        )
      } catch {
        terminate(helper)
        try? helperLog.close()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: layout.directory)
        throw error
      }
    #endif
  }

  public func shutdownGuest() async {
    try? await agent.umount(path: rootPath, flags: 0)
    try? await agent.sync()
    await shutdownVMM()
  }

  /// Open an independent control connection to vminitd for one process lifecycle.
  ///
  /// Apple Containerization gives each LinuxProcess its own agent connection. Keep
  /// the long-running init wait and exec waits off the controller connection so a
  /// completed exec cannot interfere with VM-level RPCs or the init process waiter.
  public func dialAgent() async throws -> Vminitd {
    try await Self.connectAgent(
      socketPath: socketLayout.controlPath,
      helper: helper,
      helperLogPath: bundle.filePath(for: "krun-vmm.log"),
      group: group
    )
  }

  public func shutdownVMM() async {
    try? await agent.close()
    Self.terminate(helper)
    try? helperLogHandle.close()
    try? await group.shutdownGracefully()
    try? FileManager.default.removeItem(at: socketLayout.directory)
  }

  private static func connectAgent(
    socketPath: String,
    helper: Foundation.Process,
    helperLogPath: URL,
    group: MultiThreadedEventLoopGroup
  ) async throws -> Vminitd {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var lastError: Error?
    repeat {
      guard helper.isRunning else {
        let log = (try? String(contentsOf: helperLogPath, encoding: .utf8)) ?? ""
        throw ContainerizationError(
          .internalError,
          message: "libkrun helper exited before vminitd became reachable: \(log)"
        )
      }
      do {
        let connection = try Socket(type: UnixType(path: socketPath), closeOnDeinit: false)
        do {
          try connection.connect()
          let fd = dup(connection.fileDescriptor)
          guard fd >= 0 else { throw POSIXError(.EIO) }
          try connection.close()
          let agent = try await Vminitd(
            connection: FileHandle(fileDescriptor: fd, closeOnDealloc: false),
            group: group
          )
          do {
            // libkrun creates the host UDS before vminitd starts serving.
            // Require a real RPC so bootstrap cannot race guest readiness.
            _ = try await agent.containerStatistics(containerIDs: [], categories: [])
            return agent
          } catch {
            try? await agent.close()
            throw error
          }
        } catch {
          try? connection.close()
          throw error
        }
      } catch {
        lastError = error
        try await Task.sleep(for: .milliseconds(100))
      }
    } while ContinuousClock.now < deadline

    throw ContainerizationError(
      .timeout,
      message: "vminitd was not ready within 30 seconds: \(String(describing: lastError))"
    )
  }

  private static func requireExt4Block(_ filesystem: Filesystem, name: String) throws {
    guard case .block(let format, _, _) = filesystem.type, format == "ext4" else {
      throw ContainerizationError(
        .unsupported,
        message: "container-runtime-krun v0.1 requires an ext4 block \(name)"
      )
    }
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
