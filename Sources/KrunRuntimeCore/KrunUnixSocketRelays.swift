import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import KrunVMMProtocol
import SystemPackage

#if canImport(Darwin)
  import Darwin
#endif

struct KrunUnixSocketRelay: Sendable {
  let port: UInt32
  let mapping: KrunVsockMapping
  let configuration: UnixSocketConfiguration
  let ociMount: ContainerizationOCI.Mount?
  let ownedHostPath: String?
  let hostPermissions: UInt32?
}

enum KrunUnixSocketRelays {
  static let sshGuestPath = "/var/host-services/ssh-auth.sock"
  static let sshAuthSocketEnvVar = "SSH_AUTH_SOCK"

  static func make(
    config: ContainerConfiguration,
    dynamicEnv: [String: String],
    rootPath: String,
    volumeAttachments: [KrunVolumeAttachment],
    virtioFSShares: [KrunVirtioFSShare] = []
  ) throws -> [KrunUnixSocketRelay] {
    var relays: [KrunUnixSocketRelay] = []
    relays.reserveCapacity(config.publishedSockets.count + (config.ssh ? 1 : 0))

    for published in config.publishedSockets {
      let containerPath = URL(filePath: published.containerPath.string)
      let guestPath = KrunContainerPath.resolve(
        config: config,
        rootPath: rootPath,
        volumeAttachments: volumeAttachments,
        virtioFSShares: virtioFSShares,
        path: containerPath
      ).url
      try validateGuestSocketPath(guestPath.path)

      let hostPath = published.hostPath.string
      try validateHostSocketPath(hostPath)
      let port = try port(for: relays.count)
      let socket = UnixSocketConfiguration(
        source: guestPath,
        destination: URL(filePath: hostPath),
        direction: .outOf
      )
      relays.append(
        KrunUnixSocketRelay(
          port: port,
          mapping: KrunVsockMapping(port: port, path: hostPath, listen: true),
          configuration: socket,
          ociMount: nil,
          ownedHostPath: hostPath,
          hostPermissions: published.permissions.map { UInt32($0.rawValue) }
        )
      )
    }

    if config.ssh,
      let hostPath = dynamicEnv[sshAuthSocketEnvVar],
      !hostPath.isEmpty
    {
      try validateHostSocketPath(hostPath)
      let port = try port(for: relays.count)
      let stagingPath = sshStagingPath(containerID: config.id)
      try validateGuestSocketPath(stagingPath)
      let hostPermissions = sshSocketPermissions(hostPath: hostPath)
      let socket = UnixSocketConfiguration(
        source: URL(filePath: hostPath),
        destination: URL(filePath: stagingPath),
        permissions: hostPermissions,
        direction: .into
      )
      relays.append(
        KrunUnixSocketRelay(
          port: port,
          mapping: KrunVsockMapping(port: port, path: hostPath, listen: false),
          configuration: socket,
          ociMount: ContainerizationOCI.Mount(
            type: "bind",
            source: stagingPath,
            destination: sshGuestPath,
            options: ["bind"]
          ),
          ownedHostPath: nil,
          hostPermissions: nil
        )
      )
    }

    return relays
  }

  static func prepareHostPaths(_ relays: [KrunUnixSocketRelay]) throws {
    for relay in relays {
      guard let path = relay.ownedHostPath else { continue }
      if FileManager.default.fileExists(atPath: path) {
        throw ContainerizationError(
          .invalidArgument,
          message: "published Unix socket host path already exists: \(path)"
        )
      }
      try FileManager.default.createDirectory(
        at: URL(filePath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
  }

  static func applyHostPermissions(_ relays: [KrunUnixSocketRelay]) throws {
    #if canImport(Darwin)
      for relay in relays {
        guard let path = relay.ownedHostPath, let permissions = relay.hostPermissions else {
          continue
        }
        guard chmod(path, mode_t(permissions)) == 0 else {
          throw ContainerizationError(
            .internalError,
            message:
              "failed to set published Unix socket permissions for \(path): \(String(cString: strerror(errno)))"
          )
        }
      }
    #endif
  }

  static func start(_ relays: [KrunUnixSocketRelay], agent: Vminitd) async throws {
    do {
      for relay in relays {
        try await agent.relaySocket(port: relay.port, configuration: relay.configuration)
      }
    } catch {
      await stop(relays, agent: agent)
      throw error
    }
  }

  static func stop(_ relays: [KrunUnixSocketRelay], agent: Vminitd) async {
    for relay in relays.reversed() {
      try? await agent.stopSocketRelay(configuration: relay.configuration)
    }
  }

  static func cleanupHostPaths(_ relays: [KrunUnixSocketRelay]) {
    for relay in relays {
      guard let path = relay.ownedHostPath else { continue }
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  static func ociMounts(_ relays: [KrunUnixSocketRelay]) -> [ContainerizationOCI.Mount] {
    relays.compactMap(\.ociMount)
  }

  private static func port(for index: Int) throws -> UInt32 {
    guard let offset = UInt32(exactly: index) else {
      throw ContainerizationError(.invalidArgument, message: "too many Unix socket relays")
    }
    let (port, overflow) = KrunDefaults.firstRelayPort.addingReportingOverflow(offset)
    guard !overflow else {
      throw ContainerizationError(.invalidArgument, message: "too many Unix socket relays")
    }
    return port
  }

  private static func sshStagingPath(containerID: String) -> String {
    let safeID = String(containerID.prefix(12)).replacingOccurrences(of: "/", with: "_")
    return "/run/ckr-\(safeID)-ssh.sock"
  }

  private static func validateHostSocketPath(_ path: String) throws {
    // Darwin sockaddr_un.sun_path is 104 bytes including the trailing NUL.
    guard path.utf8.count <= 103 else {
      throw ContainerizationError(
        .invalidArgument,
        message: "host Unix socket path is too long for macOS: \(path)"
      )
    }
  }

  private static func validateGuestSocketPath(_ path: String) throws {
    // Linux sockaddr_un.sun_path is 108 bytes including the trailing NUL.
    guard path.utf8.count <= 107 else {
      throw ContainerizationError(
        .invalidArgument,
        message: "guest Unix socket path is too long: \(path)"
      )
    }
  }

  private static func sshSocketPermissions(hostPath: String) -> FilePermissions? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: hostPath)
    return (attrs?[.posixPermissions] as? NSNumber)
      .map { FilePermissions(rawValue: .init($0.intValue)) }
  }

}
