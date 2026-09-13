import ContainerNetworkClient
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging
import NIOCore
import SocketForwarder


public actor KrunRuntimeService {
  public enum State: Sendable, Equatable {
    case created
    case booted
    case running
    case stopping
    case stopped
    case shuttingDown
  }

  private struct ProcessRecord {
    let configuration: ProcessConfiguration
    let hostStdio: [FileHandle?]
    var agent: Vminitd?
    var io: KrunProcessIO?
    var waitTask: Task<ExitStatus, Error>?
    var exitStatus: ExitStatus?
    var started = false
  }

  private let root: URL
  private let connection: xpc_connection_t
  private let log: Logger
  private let helperPath: String

  private var state: State = .created
  private var vm: KrunVMController?
  private var config: ContainerConfiguration?
  private var portPool: KrunPortPool?
  private var copyPortPool: KrunPortPool?
  private var processes: [String: ProcessRecord] = [:]
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var networkSessions: [XPCClientSession] = []
  private var networkAttachments: [Attachment] = []
  private var networkBackends: [KrunVMNetBackend] = []
  private var socketForwarders: [SocketForwarderResult] = []
  private var lifecycleStartedAt: ContinuousClock.Instant?

  public init(
    root: URL,
    connection: xpc_connection_t,
    helperPath: String,
    log: Logger
  ) {
    self.root = root
    self.connection = connection
    self.helperPath = helperPath
    self.log = log
  }

  @Sendable
  public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
    let endpoint = xpc_endpoint_create(connection)
    let reply = message.reply()
    reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
    return reply
  }

  @Sendable
  public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .created || state == .stopped else {
      throw ContainerizationError(
        .invalidState, message: "runtime is not in a bootstrappable state")
    }

    let startedAt = ContinuousClock.now
    lifecycleStartedAt = startedAt
    KrunLifecycleTrace.mark(log, startedAt: startedAt, event: "bootstrap start")
    let networkInfos = try message.networkBootstrapInfos()
    let dynamicEnv = try message.dynamicEnvironment()

    let bundle = try ensureBundle()
    let containerConfig = try bundle.configuration
    try KrunFeatureGate.validate(containerConfig)
    let networkResources = try await prepareNetworking(
      config: containerConfig,
      networkInfos: networkInfos,
      bundle: bundle,
      startedAt: startedAt
    )
    let controller: KrunVMController
    do {
      controller = try await KrunVMController.boot(
        bundle: bundle,
        helperPath: helperPath,
        networkConfigs: networkResources.backends.map(\.networkConfig),
        networkAttachments: networkResources.attachments,
        dynamicEnv: dynamicEnv,
        lifecycleStartedAt: startedAt,
        log: log
      )
    } catch {
      for backend in networkResources.backends { backend.stop() }
      for session in networkResources.sessions { session.close() }
      throw error
    }
    let forwarders: [SocketForwarderResult]
    do {
      forwarders = try await startSocketForwarders(
        attachment: networkResources.attachments.first,
        publishedPorts: containerConfig.publishedPorts,
        eventLoopGroup: controller.eventLoopGroup
      )
    } catch {
      await controller.shutdownGuest()
      for backend in networkResources.backends { backend.stop() }
      for session in networkResources.sessions { session.close() }
      throw error
    }

    let pool = KrunPortPool(entries: controller.socketLayout.ioEntries, name: "stdio")
    let copyPool = KrunPortPool(entries: controller.socketLayout.copyEntries, name: "copy")
    let stdio = message.stdioHandles()

    // Match Apple's runtime lifecycle boundary: bootstrap owns VM/guest setup only.
    // Register the init process metadata here, but defer OCI process creation and
    // stdio/vsock setup until the API server invokes startProcess().
    self.vm = controller
    self.config = containerConfig
    self.portPool = pool
    self.copyPortPool = copyPool
    self.networkSessions = networkResources.sessions
    self.networkAttachments = networkResources.attachments
    self.networkBackends = networkResources.backends
    self.socketForwarders = forwarders
    self.processes = [
      containerConfig.id: ProcessRecord(
        configuration: containerConfig.initProcess,
        hostStdio: stdio
      )
    ]
    self.state = .booted
    KrunLifecycleTrace.mark(log, startedAt: startedAt, event: "bootstrap reply")
    return message.reply()
  }

  @Sendable
  public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running || state == .booted else {
      throw ContainerizationError(.invalidState, message: "cannot exec: container is not running")
    }
    let id = try message.id()
    guard processes[id] == nil else {
      throw ContainerizationError(.invalidArgument, message: "process \(id) already exists")
    }
    let processConfig = try message.processConfiguration()
    let stdio = message.stdioHandles()
    processes[id] = ProcessRecord(
      configuration: processConfig,
      hostStdio: stdio
    )
    return message.reply()
  }

  @Sendable
  public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
    let id = try message.id()
    let startedAt = lifecycleStartedAt ?? ContinuousClock.now
    KrunLifecycleTrace.mark(
      log,
      startedAt: startedAt,
      event: "startProcess start",
      metadata: ["process_id": "\(id)"]
    )
    guard let controller = vm, let containerConfig = config, let pool = portPool else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    guard var record = processes[id] else {
      throw ContainerizationError(.notFound, message: "process \(id) is not registered")
    }
    guard !record.started else {
      return message.reply()
    }

    let isInit = id == containerConfig.id
    let io = try await KrunProcessIO.prepare(
      hostHandles: record.hostStdio,
      terminal: record.configuration.terminal,
      pool: pool
    )
    let processAgent: Vminitd
    do {
      processAgent = try await controller.dialAgent()
    } catch {
      await io.close()
      throw error
    }
    var processCreated = false
    do {
      let spec = try KrunSpecBuilder.make(
        container: containerConfig,
        process: record.configuration,
        rootPath: controller.rootPath,
        volumeAttachments: controller.volumeAttachments,
        socketMounts: controller.socketMounts,
        wrapWithInit: isInit && containerConfig.useInit
      )
      try await processAgent.createProcess(
        id: id,
        containerID: containerConfig.id,
        stdinPort: io.stdinPort,
        stdoutPort: io.stdoutPort,
        stderrPort: io.stderrPort,
        ociRuntimePath: nil,
        configuration: spec,
        options: nil
      )
      processCreated = true
      KrunLifecycleTrace.mark(
        log,
        startedAt: startedAt,
        event: "guest process created",
        metadata: ["process_id": "\(id)"]
      )
      try await io.waitForGuestConnections()
      KrunLifecycleTrace.mark(
        log,
        startedAt: startedAt,
        event: "guest stdio connected",
        metadata: ["process_id": "\(id)"]
      )
      _ = try await processAgent.startProcess(id: id, containerID: containerConfig.id)
      KrunLifecycleTrace.mark(
        log,
        startedAt: startedAt,
        event: "guest process started",
        metadata: ["process_id": "\(id)"]
      )
    } catch {
      if processCreated {
        try? await processAgent.deleteProcess(id: id, containerID: containerConfig.id)
      }
      await io.close()
      try? await processAgent.close()
      throw error
    }
    record.agent = processAgent
    record.io = io
    io.startRelays(agent: processAgent, id: id, containerID: containerConfig.id)
    let containerID = containerConfig.id
    record.waitTask = Task {
      let status = try await processAgent.waitProcess(id: id, containerID: containerID)
      await io.waitForOutput()
      await self.finalizeProcessExit(id: id, status: status)
      return status
    }
    record.started = true
    processes[id] = record
    if isInit {
      state = .running
    }
    return message.reply()
  }

  @Sendable
  public func stateSnapshot(_ message: XPCMessage) async throws -> XPCMessage {
    let runtimeStatus: RuntimeStatus
    switch state {
    case .running:
      runtimeStatus = .running
    case .stopping:
      runtimeStatus = .stopping
    case .created, .booted, .stopped, .shuttingDown:
      runtimeStatus = .stopped
    }

    var containers: [ContainerSnapshot] = []
    if let config, runtimeStatus == .running {
      containers = [
        ContainerSnapshot(
          configuration: config,
          status: .running,
          networks: networkAttachments
        )
      ]
    }
    let snapshot = SandboxSnapshot(
      status: runtimeStatus,
      networks: runtimeStatus == .running ? networkAttachments : [],
      containers: containers
    )
    let reply = message.reply()
    reply.set(key: RuntimeKeys.snapshot.rawValue, value: try JSONEncoder().encode(snapshot))
    return reply
  }

  @Sendable
  public func wait(_ message: XPCMessage) async throws -> XPCMessage {
    let id = try message.id()
    let status = try await waitForProcess(id)
    let reply = message.reply()
    reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(status.exitCode))
    reply.set(key: RuntimeKeys.exitedAt.rawValue, value: status.exitedAt)
    return reply
  }

  @Sendable
  public func kill(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running else {
      throw ContainerizationError(.invalidState, message: "cannot kill: container is not running")
    }
    let id = try message.id()
    guard let signalName = message.string(key: RuntimeKeys.signal.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "missing signal")
    }
    let signal = try Signal(signalName)
    guard let config else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    guard let agent = processes[id]?.agent, processes[id]?.started == true else {
      throw ContainerizationError(.invalidState, message: "process \(id) is not started")
    }
    try await agent.signalProcess(
      id: id, containerID: config.id, signal: signal.rawValue)
    if signal == .kill {
      _ = try await waitForProcess(id)
    }
    return message.reply()
  }

  @Sendable
  public func resize(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running else {
      throw ContainerizationError(.invalidState, message: "cannot resize: container is not running")
    }
    let id = try message.id()
    guard let config else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    guard let agent = processes[id]?.agent else {
      throw ContainerizationError(.invalidState, message: "process \(id) is not started")
    }
    try await agent.resizeProcess(
      id: id,
      containerID: config.id,
      columns: UInt32(message.uint64(key: RuntimeKeys.width.rawValue)),
      rows: UInt32(message.uint64(key: RuntimeKeys.height.rawValue))
    )
    return message.reply()
  }

  @Sendable
  public func statistics(_ message: XPCMessage) async throws -> XPCMessage {
    guard let controller = vm, let config else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    let categories: StatCategory = [.process, .memory, .cpu, .blockIO, .network]
    let stats = try await controller.agent.containerStatistics(
      containerIDs: [config.id],
      categories: categories
    ).first
    let result = ContainerStats(
      id: config.id,
      memoryUsageBytes: stats?.memory?.usageBytes,
      memoryLimitBytes: stats?.memory?.limitBytes,
      cpuUsageUsec: stats?.cpu?.usageUsec,
      networkRxBytes: stats?.networks?.reduce(0) { $0 + $1.receivedBytes },
      networkTxBytes: stats?.networks?.reduce(0) { $0 + $1.transmittedBytes },
      blockReadBytes: stats?.blockIO?.devices.reduce(0) { $0 + $1.readBytes },
      blockWriteBytes: stats?.blockIO?.devices.reduce(0) { $0 + $1.writeBytes },
      numProcesses: stats?.process?.current
    )
    let reply = message.reply()
    reply.set(key: RuntimeKeys.statistics.rawValue, value: try JSONEncoder().encode(result))
    return reply
  }

  @Sendable
  public func stop(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running || state == .booted else {
      return message.reply()
    }
    state = .stopping
    let options = try message.stopOptions()
    guard let config else {
      throw ContainerizationError(.invalidState, message: "runtime has no container configuration")
    }

    if processes[config.id]?.started == true, let controller = vm {
      let signal = try Signal(options.signal ?? config.stopSignal ?? "SIGTERM")
      try await controller.agent.signalProcess(
        id: config.id, containerID: config.id, signal: signal.rawValue)
      do {
        _ = try await controller.agent.waitProcess(
          id: config.id,
          containerID: config.id,
          timeoutInSeconds: Int64(options.timeoutInSeconds)
        )
      } catch let error as ContainerizationError where error.code == .timeout {
        try await controller.agent.signalProcess(
          id: config.id, containerID: config.id, signal: Signal.kill.rawValue)
        _ = try await controller.agent.waitProcess(id: config.id, containerID: config.id)
      }
    }
    await cleanupContainer()
    return message.reply()
  }

  @Sendable
  public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .created || state == .stopped || state == .stopping else {
      throw ContainerizationError(.invalidState, message: "cannot shutdown a running container")
    }
    state = .shuttingDown
    return message.reply()
  }

  @Sendable public func dial(_ message: XPCMessage) async throws -> XPCMessage {
    throw unsupported("dial")
  }

  @Sendable
  public func copyIn(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running || state == .booted else {
      throw ContainerizationError(.invalidState, message: "cannot copyIn: container is not running")
    }
    guard let controller = vm, let copyPool = copyPortPool else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    guard let sourcePath = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "no source path supplied for copyIn")
    }
    guard let destinationPath = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "no destination path supplied for copyIn")
    }

    try await KrunCopyOperations.copyIn(
      controller: controller,
      pool: copyPool,
      source: URL(fileURLWithPath: sourcePath),
      destination: URL(fileURLWithPath: destinationPath),
      mode: UInt32(message.uint64(key: RuntimeKeys.fileMode.rawValue)),
      createParents: message.bool(key: RuntimeKeys.createParents.rawValue)
    )
    return message.reply()
  }

  @Sendable
  public func copyOut(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running || state == .booted else {
      throw ContainerizationError(.invalidState, message: "cannot copyOut: container is not running")
    }
    guard let controller = vm, let copyPool = copyPortPool else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    guard let sourcePath = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "no source path supplied for copyOut")
    }
    guard let destinationPath = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "no destination path supplied for copyOut")
    }

    try await KrunCopyOperations.copyOut(
      controller: controller,
      pool: copyPool,
      source: URL(fileURLWithPath: sourcePath),
      destination: URL(fileURLWithPath: destinationPath),
      createParents: message.bool(key: RuntimeKeys.createParents.rawValue)
    )
    return message.reply()
  }

  @Sendable
  public func snapshotDisk(_ message: XPCMessage) async throws -> XPCMessage {
    guard state == .running || state == .booted else {
      throw ContainerizationError(
        .invalidState,
        message: "cannot snapshot disk: container is not running or booted"
      )
    }
    guard let controller = vm else {
      throw ContainerizationError(.invalidState, message: "runtime is not booted")
    }
    guard let imagePath = message.string(key: RuntimeKeys.imagePath.rawValue) else {
      throw ContainerizationError(
        .invalidArgument,
        message: "no image path supplied for snapshotDisk"
      )
    }
    guard let destinationPath = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
      throw ContainerizationError(
        .invalidArgument,
        message: "no destination path supplied for snapshotDisk"
      )
    }

    let shouldFreeze = state == .running
    if shouldFreeze {
      try await controller.agent.filesystemOperation(
        operation: .freeze,
        path: controller.rootPath
      )
    }

    do {
      try FileManager.default.copyItem(atPath: imagePath, toPath: destinationPath)
    } catch {
      if shouldFreeze {
        do {
          try await controller.agent.filesystemOperation(
            operation: .thaw,
            path: controller.rootPath
          )
        } catch {
          log.error(
            "failed to thaw filesystem after snapshotDisk error",
            metadata: ["error": "\(error)"]
          )
        }
      }
      throw error
    }

    if shouldFreeze {
      try await controller.agent.filesystemOperation(
        operation: .thaw,
        path: controller.rootPath
      )
    }
    return message.reply()
  }

  private func unsupported(_ route: String) -> ContainerizationError {
    KrunFeatureGate.unsupported("runtime route \(route)")
  }

  private func waitForProcess(_ id: String) async throws -> ExitStatus {
    guard let record = processes[id] else {
      throw ContainerizationError(.notFound, message: "process \(id) does not exist")
    }

    let status: ExitStatus
    if let exitStatus = record.exitStatus {
      status = exitStatus
    } else {
      guard let task = record.waitTask else {
        throw ContainerizationError(.invalidState, message: "process \(id) has not started")
      }
      status = try await task.value
    }

    // During an explicit stop, keep the API server's background init waiter blocked
    // until stop() has finished VM cleanup. Otherwise the API server can deregister
    // this runtime service while the stop XPC reply is still in flight.
    if id == config?.id && state == .stopping {
      await waitForStopCompletion()
    }
    return status
  }

  private func finalizeProcessExit(id: String, status: ExitStatus) async {
    guard var record = processes[id] else {
      return
    }

    if id == config?.id {
      // A natural init exit owns cleanup. During an explicit stop, stop() owns cleanup
      // and the public wait path remains gated until that cleanup is complete. This
      // matches Apple's RuntimeService .stopping behavior and avoids tearing the VM
      // down underneath stop()'s graceful wait.
      if state != .stopping {
        await cleanupContainer()
      }
    } else {
      if let agent = record.agent, let config {
        try? await agent.deleteProcess(id: id, containerID: config.id)
        try? await agent.close()
      }
      await record.io?.close()
    }

    record.exitStatus = status
    record.waitTask = nil
    record.agent = nil
    processes[id] = record
  }

  private func cleanupContainer() async {
    guard let controller = vm else {
      state = .stopped
      releaseStopWaiters()
      return
    }
    // Clear ownership before any await so concurrent stop/wait cleanup is idempotent.
    vm = nil
    portPool = nil
    copyPortPool = nil
    let containerID = config?.id
    let records = processes
    // Keep completed process records until this runtime instance exits. Apple Container
    // can issue more than one wait for the init process (the API-server exit monitor and
    // the requesting client), including a wait that arrives after VM cleanup has started.
    // The cached ExitStatus in ProcessRecord is the durable answer for those late waiters.
    state = .stopping

    for (_, record) in records {
      if let io = record.io {
        await io.close()
      } else {
        for handle in record.hostStdio.compactMap({ $0 }) {
          try? handle.close()
        }
      }
      try? await record.agent?.close()
    }
    await controller.stopSocketRelays()
    if let containerID {
      await controller.unmountFilesystems()
      try? await controller.agent.deleteProcess(id: containerID, containerID: containerID)
    }
    await stopSocketForwarders()
    await controller.shutdownVMM()
    for backend in networkBackends { backend.stop() }
    networkBackends = []
    for session in networkSessions { session.close() }
    networkSessions = []
    networkAttachments = []
    state = .stopped
    releaseStopWaiters()
  }

  private func startSocketForwarders(
    attachment: Attachment?,
    publishedPorts: [PublishPort],
    eventLoopGroup: any EventLoopGroup
  ) async throws -> [SocketForwarderResult] {
    guard !publishedPorts.isEmpty else { return [] }
    guard let attachment else {
      throw ContainerizationError(
        .invalidArgument,
        message: "published ports require a network attachment"
      )
    }
    guard !publishedPorts.hasOverlaps() else {
      throw ContainerizationError(
        .invalidArgument,
        message: "host ports for different publish port specs may not overlap"
      )
    }

    var forwarders: [SocketForwarderResult] = []
    do {
      for publishedPort in publishedPorts {
        for offset in 0..<publishedPort.count {
          let proxyAddress = try SocketAddress(
            ipAddress: publishedPort.hostAddress.description,
            port: Int(publishedPort.hostPort + offset)
          )
          let containerIPAddress: String
          switch publishedPort.hostAddress {
          case .v4(_):
            containerIPAddress = attachment.ipv4Address.address.description
          case .v6(_):
            guard let ipv6Address = attachment.ipv6Address else {
              throw ContainerizationError(
                .invalidState,
                message: "cannot configure IPv6 port forwarding for container with unknown IPv6 address"
              )
            }
            containerIPAddress = ipv6Address.address.description
          }
          let serverAddress = try SocketAddress(
            ipAddress: containerIPAddress,
            port: Int(publishedPort.containerPort + offset)
          )
          log.info(
            "creating port forwarder",
            metadata: [
              "protocol": "\(publishedPort.proto.rawValue)",
              "proxy": "\(proxyAddress)",
              "server": "\(serverAddress)",
            ]
          )

          let forwarder: any SocketForwarder
          switch publishedPort.proto {
          case .tcp:
            forwarder = try TCPForwarder(
              proxyAddress: proxyAddress,
              serverAddress: serverAddress,
              eventLoopGroup: eventLoopGroup,
              log: log
            )
          case .udp:
            forwarder = try UDPForwarder(
              proxyAddress: proxyAddress,
              serverAddress: serverAddress,
              eventLoopGroup: eventLoopGroup,
              log: log
            )
          }

          do {
            forwarders.append(try await forwarder.run().get())
          } catch let error as IOError where error.errnoCode == EACCES {
            if let port = proxyAddress.port, port < 1024 {
              throw ContainerizationError(
                .invalidArgument,
                message: "permission denied while binding host port \(port); ports below 1024 require root privileges"
              )
            }
            throw error
          }
        }
      }
      return forwarders
    } catch {
      await closeSocketForwarders(forwarders)
      throw error
    }
  }

  private func stopSocketForwarders() async {
    let forwarders = socketForwarders
    socketForwarders = []
    await closeSocketForwarders(forwarders)
  }

  private func closeSocketForwarders(_ forwarders: [SocketForwarderResult]) async {
    for forwarder in forwarders {
      forwarder.close()
    }
    for forwarder in forwarders {
      try? await forwarder.wait()
    }
  }

  private struct NetworkResources {
    let sessions: [XPCClientSession]
    let attachments: [Attachment]
    let backends: [KrunVMNetBackend]
  }

  private func prepareNetworking(
    config: ContainerConfiguration,
    networkInfos: [NetworkBootstrapInfo],
    bundle: ContainerResource.Bundle,
    startedAt: ContinuousClock.Instant
  ) async throws -> NetworkResources {
    guard config.networks.count == networkInfos.count else {
      throw ContainerizationError(
        .invalidArgument,
        message: "network configuration and bootstrap info counts do not match"
      )
    }
    guard !networkInfos.isEmpty else {
      return NetworkResources(sessions: [], attachments: [], backends: [])
    }

    var sessions: [XPCClientSession] = []
    var attachments: [Attachment] = []
    var backends: [KrunVMNetBackend] = []
    do {
      for (index, info) in networkInfos.enumerated() {
        guard info.plugin == "container-network-vmnet" else {
          throw KrunFeatureGate.unsupported("network plugin \(info.plugin)")
        }
        let attachmentConfig = config.networks[index]
        let client = NetworkClient(id: attachmentConfig.network, plugin: info.plugin)
        let session = client.connect()
        sessions.append(session)
        KrunLifecycleTrace.mark(
          log,
          startedAt: startedAt,
          event: "network allocation start",
          metadata: [
            "network": "\(attachmentConfig.network)",
            "network_index": "\(index)",
          ]
        )
        var (attachment, _) = try await client.allocate(
          hostname: attachmentConfig.options.hostname,
          macAddress: attachmentConfig.options.macAddress,
          on: session
        )
        KrunLifecycleTrace.mark(
          log,
          startedAt: startedAt,
          event: "network allocation complete",
          metadata: [
            "ipv4": "\(attachment.ipv4Address)",
            "network": "\(attachment.network)",
            "network_index": "\(index)",
            "variant": "\(attachment.variant ?? "unknown")",
          ]
        )
        if let mtu = attachmentConfig.options.mtu {
          attachment = Attachment(
            network: attachment.network,
            hostname: attachment.hostname,
            ipv4Address: attachment.ipv4Address,
            ipv4Gateway: attachment.ipv4Gateway,
            ipv6Address: attachment.ipv6Address,
            macAddress: attachment.macAddress,
            mtu: mtu,
            variant: attachment.variant
          )
        }
        let backend = try await KrunVMNetBackend.start(
          attachment: attachment,
          index: index,
          logPath: bundle.filePath(for: "krun-vmnet-\(index).log"),
          lifecycleStartedAt: startedAt,
          log: log
        )
        attachments.append(attachment)
        backends.append(backend)
      }
      return NetworkResources(
        sessions: sessions,
        attachments: attachments,
        backends: backends
      )
    } catch {
      for backend in backends { backend.stop() }
      for session in sessions { session.close() }
      throw error
    }
  }

  private func waitForStopCompletion() async {
    guard state == .stopping else {
      return
    }
    await withCheckedContinuation { continuation in
      if state == .stopping {
        stopWaiters.append(continuation)
      } else {
        continuation.resume()
      }
    }
  }

  private func releaseStopWaiters() {
    let waiters = stopWaiters
    stopWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func ensureBundle() throws -> ContainerResource.Bundle {
    let existing = ContainerResource.Bundle(path: root)
    if (try? existing.configuration) != nil {
      return existing
    }
    let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: root)
    return try ContainerResource.Bundle.create(
      path: runtimeConfig.path,
      initialFilesystem: runtimeConfig.initialFilesystem,
      kernel: runtimeConfig.kernel,
      containerConfiguration: runtimeConfig.containerConfiguration,
      containerRootFilesystem: runtimeConfig.containerRootFilesystem,
      options: runtimeConfig.options
    )
  }
}

extension XPCMessage {
  fileprivate func stdioHandles() -> [FileHandle?] {
    [
      fileHandle(key: RuntimeKeys.stdin.rawValue),
      fileHandle(key: RuntimeKeys.stdout.rawValue),
      fileHandle(key: RuntimeKeys.stderr.rawValue),
    ]
  }

  fileprivate func dynamicEnvironment() throws -> [String: String] {
    guard let data = dataNoCopy(key: RuntimeKeys.dynamicEnv.rawValue) else {
      return [:]
    }
    return try JSONDecoder().decode([String: String].self, from: data)
  }

  fileprivate func processConfiguration() throws -> ProcessConfiguration {
    guard let data = dataNoCopy(key: RuntimeKeys.processConfig.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "missing process configuration")
    }
    return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
  }

  fileprivate func stopOptions() throws -> ContainerStopOptions {
    guard let data = dataNoCopy(key: RuntimeKeys.stopOptions.rawValue) else {
      throw ContainerizationError(.invalidArgument, message: "missing stop options")
    }
    return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
  }
}
