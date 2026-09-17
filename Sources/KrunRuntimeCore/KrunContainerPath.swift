import ContainerResource
import Foundation

struct KrunResolvedContainerPath: Sendable {
  let root: String
  let path: String
  let readOnly: Bool

  var url: URL {
    guard path != "/" else { return URL(filePath: root) }
    return URL(filePath: root).appending(path: String(path.dropFirst()))
  }

  func appendingPathComponent(_ component: String) -> KrunResolvedContainerPath {
    let appendedPath = URL(filePath: path).appending(path: component).path
    return KrunResolvedContainerPath(root: root, path: appendedPath, readOnly: readOnly)
  }
}

enum KrunContainerPath {
  /// Translate a path from the container mount namespace to the guest filesystem
  /// root and path that vminitd can access. Block-backed volumes and virtiofs
  /// shares are staged outside the rootfs and bind-mounted into the OCI
  /// namespace, so operations that run in vminitd's namespace must use the
  /// staging mount as their root.
  static func resolve(
    controller: KrunVMController,
    path: URL
  ) -> KrunResolvedContainerPath {
    resolve(
      config: controller.config,
      rootPath: controller.rootPath,
      volumeAttachments: controller.volumeAttachments,
      virtioFSShares: controller.virtioFSShares,
      path: path
    )
  }

  static func resolve(
    config: ContainerConfiguration,
    rootPath: String,
    volumeAttachments: [KrunVolumeAttachment],
    virtioFSShares: [KrunVirtioFSShare] = [],
    path: URL
  ) -> KrunResolvedContainerPath {
    let containerPath = normalizedAbsolutePath(path.path)
    let attachments = Dictionary(
      uniqueKeysWithValues: volumeAttachments.map { ($0.name, $0) }
    )

    var matchedDestination: String?
    var matchedAttachment: KrunVolumeAttachment?
    var matchedShare: KrunVirtioFSShare?
    var matchedReadOnly = false

    for filesystem in config.mounts {
      guard case .volume(let name, _, _, _) = filesystem.type,
        let attachment = attachments[name]
      else {
        continue
      }

      let destination = normalizedAbsolutePath(filesystem.destination)
      guard contains(containerPath, inMount: destination) else { continue }
      if let current = matchedDestination, current.count >= destination.count {
        continue
      }

      matchedDestination = destination
      matchedAttachment = attachment
      matchedShare = nil
      matchedReadOnly = filesystem.options.contains("ro")
    }

    for share in virtioFSShares {
      let destination = normalizedAbsolutePath(share.destination)
      guard contains(containerPath, inMount: destination) else { continue }
      if let current = matchedDestination, current.count >= destination.count {
        continue
      }

      matchedDestination = destination
      matchedAttachment = nil
      matchedShare = share
      matchedReadOnly = share.readOnly
    }

    guard let destination = matchedDestination else {
      return KrunResolvedContainerPath(
        root: rootPath,
        path: containerPath,
        readOnly: false
      )
    }

    let relative: String
    if containerPath == destination {
      relative = "/"
    } else if destination == "/" {
      relative = containerPath
    } else {
      relative = String(containerPath.dropFirst(destination.count))
    }

    let stagingRoot: String
    if let attachment = matchedAttachment {
      stagingRoot = attachment.stagingPath
    } else if let share = matchedShare {
      stagingRoot = share.stagingPath
    } else {
      return KrunResolvedContainerPath(
        root: rootPath,
        path: containerPath,
        readOnly: config.readOnly
      )
    }

    return KrunResolvedContainerPath(
      root: stagingRoot,
      path: relative,
      readOnly: matchedReadOnly
    )
  }

  private static func normalizedAbsolutePath(_ path: String) -> String {
    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
    guard normalized.count > 1 else { return "/" }
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
  }

  private static func contains(_ path: String, inMount mount: String) -> Bool {
    if mount == "/" { return path.hasPrefix("/") }
    return path == mount || path.hasPrefix("\(mount)/")
  }
}
