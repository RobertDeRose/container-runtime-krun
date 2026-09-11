import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPCCore
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
    networkConfigs: [KrunNetworkConfig] = [],
    networkAttachments: [Attachment] = [],
    lifecycleStartedAt: ContinuousClock.Instant = ContinuousClock.now,
    libkrunPath: String = KrunDefaults.libkrunPath,
    log: Logger
  ) async throws -> KrunVMController {
    #if !os(macOS) || !arch(arm64)
      throw ContainerizationError(
        .unsupported, message: "container-runtime-krun requires Apple Silicon")
    #else
      let config = try bundle.configuration
      try KrunFeatureGate.validate(config)
      guard networkConfigs.count == networkAttachments.count else {
        throw ContainerizationError(
          .invalidArgument,
          message: "network config and attachment counts do not match"
        )
      }
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
        vsockMappings: layout.mappings,
        networks: networkConfigs
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
      KrunLifecycleTrace.mark(
        log,
        startedAt: lifecycleStartedAt,
        event: "libkrun helper launch"
      )
      try helper.run()
      KrunLifecycleTrace.mark(
        log,
        startedAt: lifecycleStartedAt,
        event: "libkrun helper launched",
        metadata: ["pid": "\(helper.processIdentifier)"]
      )

      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let agent: Vminitd
      do {
        agent = try await connectAgent(
          socketPath: layout.controlPath,
          helper: helper,
          helperLogPath: helperLogPath,
          group: group,
          log: log,
          lifecycleStartedAt: lifecycleStartedAt
        )
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "guest setup start"
        )
        try await agent.standardSetup()
        let sysctls = KrunSpecBuilder.guestSysctls(config)
        if !sysctls.isEmpty {
          try await agent.sysctl(settings: sysctls)
        }
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "guest setup complete"
        )
        let rootPath = KrunSpecBuilder.guestRootPath(containerID: config.id)
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "rootfs mount start"
        )
        try await agent.mkdir(path: rootPath, all: true, perms: 0o755)
        try await agent.mount(
          ContainerizationOCI.Mount(
            type: "ext4",
            source: "/dev/vdb",
            destination: rootPath
          )
        )
        KrunLifecycleTrace.mark(
          log,
          startedAt: lifecycleStartedAt,
          event: "rootfs mount complete"
        )
        if !networkAttachments.isEmpty {
          KrunLifecycleTrace.mark(
            log,
            startedAt: lifecycleStartedAt,
            event: "guest network configuration start"
          )
        }
        try await configureNetworking(
          agent: agent,
          config: config,
          attachments: networkAttachments,
          rootPath: rootPath,
          lifecycleStartedAt: lifecycleStartedAt,
          log: log
        )
        if !networkAttachments.isEmpty {
          KrunLifecycleTrace.mark(
            log,
            startedAt: lifecycleStartedAt,
            event: "guest network configuration complete"
          )
        }
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
      group: group,
      log: log,
      lifecycleStartedAt: nil
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
    group: MultiThreadedEventLoopGroup,
    log: Logger,
    lifecycleStartedAt: ContinuousClock.Instant?
  ) async throws -> Vminitd {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var lastError: Error?
    var loggedTransportConnection = false
    var attempt = 0
    repeat {
      attempt += 1
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
          if !loggedTransportConnection, let lifecycleStartedAt {
            KrunLifecycleTrace.mark(
              log,
              startedAt: lifecycleStartedAt,
              event: "vminitd transport connected"
            )
            loggedTransportConnection = true
          }
          do {
            // libkrun can accept the host UDS before the guest is listening on the
            // forwarded vsock port. Keep readiness tied to a real vminitd RPC, but
            // bound each probe so a stale pre-listener connection is discarded and
            // retried instead of waiting for gRPC's transport failure timeout.
            if let lifecycleStartedAt {
              KrunLifecycleTrace.mark(
                log,
                startedAt: lifecycleStartedAt,
                event: "vminitd readiness RPC start",
                metadata: ["attempt": "\(attempt)"]
              )
            }
            try await probeAgentReadiness(agent)
            if let lifecycleStartedAt {
              KrunLifecycleTrace.mark(
                log,
                startedAt: lifecycleStartedAt,
                event: "first successful vminitd RPC",
                metadata: ["attempt": "\(attempt)"]
              )
            }
            return agent
          } catch {
            if let lifecycleStartedAt {
              KrunLifecycleTrace.mark(
                log,
                startedAt: lifecycleStartedAt,
                event: "vminitd readiness RPC failed",
                metadata: [
                  "attempt": "\(attempt)",
                  "error": "\(String(describing: error))",
                ]
              )
            }
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

  private static func probeAgentReadiness(_ agent: Vminitd) async throws {
    let client = Com_Apple_Containerization_Sandbox_V3_SandboxContext.Client(
      wrapping: agent.grpcClient
    )
    var options = CallOptions.defaults
    // This bounds one probe, not guest readiness. connectAgent still allows the full
    // 30-second readiness window and still requires a successful vminitd RPC.
    options.timeout = .milliseconds(250)
    _ = try await client.containerStatistics(
      Com_Apple_Containerization_Sandbox_V3_ContainerStatisticsRequest(),
      options: options
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

  private static func configureNetworking(
    agent: Vminitd,
    config: ContainerConfiguration,
    attachments: [Attachment],
    rootPath: String,
    lifecycleStartedAt: ContinuousClock.Instant,
    log: Logger
  ) async throws {
    guard !attachments.isEmpty else { return }

    for (index, attachment) in attachments.enumerated() {
      let name = "eth\(index)"
      let mtu = attachment.mtu ?? 1280
      try await agent.addressAdd(
        name: name,
        address: .init(
          ipv4Address: attachment.ipv4Address,
          ipv6Address: attachment.ipv6Address
        )
      )
      KrunLifecycleTrace.mark(
        log,
        startedAt: lifecycleStartedAt,
        event: "guest network address configured",
        metadata: ["network_index": "\(index)"]
      )
      try await agent.up(name: name, mtu: mtu)
      KrunLifecycleTrace.mark(
        log,
        startedAt: lifecycleStartedAt,
        event: "guest network link up",
        metadata: ["network_index": "\(index)"]
      )

      guard index == 0 else { continue }
      let gateway = attachment.ipv4Gateway
      if !attachment.ipv4Address.contains(gateway) {
        try await agent.routeAddLink(
          name: name,
          route: .init(
            ipv4Destination: gateway,
            ipv4Source: attachment.ipv4Address.address,
            ipv6Destination: nil,
            ipv6Source: nil
          )
        )
      }
      try await agent.routeAddDefault(
        name: name,
        route: .init(ipv4Gateway: gateway, ipv6Gateway: nil)
      )
      KrunLifecycleTrace.mark(
        log,
        startedAt: lifecycleStartedAt,
        event: "guest default route configured",
        metadata: ["network_index": "\(index)"]
      )
    }

    if let dns = config.dns {
      let nameservers =
        dns.nameservers.isEmpty
        ? [attachments[0].ipv4Gateway.description]
        : dns.nameservers
      try await agent.configureDNS(
        config: DNS(
          nameservers: nameservers,
          domain: dns.domain,
          searchDomains: dns.searchDomains,
          options: dns.options
        ),
        location: rootPath
      )
      KrunLifecycleTrace.mark(
        log,
        startedAt: lifecycleStartedAt,
        event: "guest DNS configured"
      )
    }

    var hostsEntries = [Hosts.Entry.localHostIPV4()]
    hostsEntries.append(
      Hosts.Entry(
        ipAddress: attachments[0].ipv4Address.address.description,
        hostnames: [KrunSpecBuilder.hostname(for: config)]
      )
    )
    try await agent.configureHosts(
      config: Hosts(entries: hostsEntries),
      location: rootPath
    )
    KrunLifecycleTrace.mark(
      log,
      startedAt: lifecycleStartedAt,
      event: "guest hosts configured"
    )
    log.debug(
      "configured libkrun network",
      metadata: [
        "ipv4": "\(attachments[0].ipv4Address)",
        "gateway": "\(attachments[0].ipv4Gateway)",
      ]
    )
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
