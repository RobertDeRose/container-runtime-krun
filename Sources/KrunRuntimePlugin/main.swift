import ArgumentParser
import ContainerRuntimeClient
import ContainerXPC
import Foundation
import KrunRuntimeCore
import Logging

@main
struct KrunRuntimePlugin: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "container-runtime-krun",
    abstract: "Apple Container runtime backed by libkrun",
    subcommands: [Start.self]
  )
}

extension KrunRuntimePlugin {
  struct Start: AsyncParsableCommand {
    static let servicePrefix = "com.apple.container.runtime.container-runtime-krun"

    static let configuration = CommandConfiguration(
      commandName: "start",
      abstract: "Start one libkrun-backed Apple Container sandbox"
    )

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    @Option(name: .shortAndLong, help: "Sandbox UUID")
    var uuid: String

    @Option(name: .shortAndLong, help: "Root directory for the sandbox")
    var root: String

    var machServiceLabel: String {
      "\(Self.servicePrefix).\(uuid)"
    }

    func run() async throws {
      LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = debug ? .debug : .info
        return handler
      }
      let log = Logger(label: "container-runtime-krun")
      signal(SIGPIPE, SIG_IGN)

      nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)
      let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
      let helperPath = executable.deletingLastPathComponent().appendingPathComponent(
        "container-krun-vmm-helper"
      ).path
      let service = KrunRuntimeService(
        root: URL(fileURLWithPath: root),
        connection: anonymousConnection,
        helperPath: helperPath,
        log: log
      )

      let endpointServer = XPCServer(
        identifier: machServiceLabel,
        routes: [
          RuntimeRoutes.createEndpoint.rawValue: XPCServer.route(service.createEndpoint)
        ],
        log: log
      )
      let mainServer = XPCServer(
        connection: anonymousConnection,
        routes: [
          RuntimeRoutes.bootstrap.rawValue: XPCServer.route(service.bootstrap),
          RuntimeRoutes.createProcess.rawValue: XPCServer.route(service.createProcess),
          RuntimeRoutes.state.rawValue: XPCServer.route(service.stateSnapshot),
          RuntimeRoutes.stop.rawValue: XPCServer.route(service.stop),
          RuntimeRoutes.kill.rawValue: XPCServer.route(service.kill),
          RuntimeRoutes.resize.rawValue: XPCServer.route(service.resize),
          RuntimeRoutes.wait.rawValue: XPCServer.route(service.wait),
          RuntimeRoutes.start.rawValue: XPCServer.route(service.startProcess),
          RuntimeRoutes.dial.rawValue: XPCServer.route(service.dial),
          RuntimeRoutes.shutdown.rawValue: XPCServer.route(service.shutdown),
          RuntimeRoutes.statistics.rawValue: XPCServer.route(service.statistics),
          RuntimeRoutes.copyIn.rawValue: XPCServer.route(service.copyIn),
          RuntimeRoutes.copyOut.rawValue: XPCServer.route(service.copyOut),
          RuntimeRoutes.snapshotDisk.rawValue: XPCServer.route(service.snapshotDisk),
          RuntimeRoutes.clean.rawValue: XPCServer.route(service.clean),
        ],
        log: log
      )

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await endpointServer.listen() }
        group.addTask { try await mainServer.listen() }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    }
  }
}
