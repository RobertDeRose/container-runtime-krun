import ContainerResource
import Foundation

struct KrunResolvedContainerPath: Sendable {
  let url: URL
  let readOnly: Bool
}

enum KrunContainerPath {
  /// Translate a path from the container mount namespace to the guest-global path
  /// that vminitd can access. Block-backed volumes are staged outside the rootfs
  /// and bind-mounted into the OCI namespace, so operations that run in vminitd's
  /// namespace must address the staging mount instead of the shadowed rootfs path.
  static func resolve(
    controller: KrunVMController,
    path: URL
  ) -> KrunResolvedContainerPath {
    resolve(
      config: controller.config,
      rootPath: controller.rootPath,
      volumeAttachments: controller.volumeAttachments,
      path: path
    )
  }

  static func resolve(
    config: ContainerConfiguration,
    rootPath: String,
    volumeAttachments: [KrunVolumeAttachment],
    path: URL
  ) -> KrunResolvedContainerPath {
    let containerPath = normalizedAbsolutePath(path.path)
    let attachments = Dictionary(
      uniqueKeysWithValues: volumeAttachments.map { ($0.name, $0) }
    )

    var matchedDestination: String?
    var matchedAttachment: KrunVolumeAttachment?
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
      matchedReadOnly = filesystem.options.contains("ro")
    }

    guard let destination = matchedDestination, let attachment = matchedAttachment else {
      return KrunResolvedContainerPath(
        url: append(containerPath: containerPath, toGuestRoot: rootPath),
        readOnly: false
      )
    }

    let relative: String
    if containerPath == destination {
      relative = ""
    } else if destination == "/" {
      relative = String(containerPath.dropFirst())
    } else {
      relative = String(containerPath.dropFirst(destination.count + 1))
    }

    let guestPath =
      relative.isEmpty
      ? URL(filePath: attachment.stagingPath)
      : URL(filePath: attachment.stagingPath).appending(path: relative)
    return KrunResolvedContainerPath(url: guestPath, readOnly: matchedReadOnly)
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

  private static func append(containerPath: String, toGuestRoot rootPath: String) -> URL {
    if containerPath == "/" {
      return URL(filePath: rootPath)
    }
    return URL(filePath: rootPath).appending(path: String(containerPath.dropFirst()))
  }
}
