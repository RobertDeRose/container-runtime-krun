import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import KrunVMMProtocol

struct KrunVirtioFSShare: Sendable, Equatable {
  let tag: String
  let hostPath: String
  let stagingPath: String
  let destination: String
  let readOnly: Bool

  var vmmConfig: KrunVirtioFSConfig {
    KrunVirtioFSConfig(
      tag: tag,
      path: hostPath,
      readOnly: readOnly,
      semantics: .linuxSimplified
    )
  }

  var guestMount: ContainerizationOCI.Mount {
    ContainerizationOCI.Mount(
      type: "virtiofs",
      source: tag,
      destination: stagingPath,
      options: readOnly ? ["ro"] : []
    )
  }

  var ociMount: ContainerizationOCI.Mount {
    ContainerizationOCI.Mount(
      type: "bind",
      source: stagingPath,
      destination: destination,
      options: readOnly ? ["bind", "ro"] : ["bind"]
    )
  }
}

enum KrunVirtioFSLayout {
  static func shares(for config: ContainerConfiguration) throws -> [KrunVirtioFSShare] {
    var shares: [KrunVirtioFSShare] = []

    for filesystem in config.mounts {
      guard case .virtiofs = filesystem.type else { continue }

      let source = URL(fileURLWithPath: filesystem.source)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw ContainerizationError(
          .invalidArgument,
          message: "virtiofs source is not a directory: \(filesystem.source)"
        )
      }

      let index = shares.count
      shares.append(
        KrunVirtioFSShare(
          tag: "krunfs\(index)",
          hostPath: source,
          stagingPath: "/run/container/\(config.id)/virtiofs/\(index)",
          destination: filesystem.destination,
          readOnly: filesystem.options.contains("ro")
        )
      )
    }

    return shares
  }

  static func ociMounts(_ shares: [KrunVirtioFSShare]) -> [ContainerizationOCI.Mount] {
    shares.map(\.ociMount)
  }
}
