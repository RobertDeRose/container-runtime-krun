import ContainerResource
import ContainerizationError
import ContainerizationOCI
import KrunVMMProtocol

struct KrunVolumeAttachment: Sendable, Equatable {
  let name: String
  let source: String
  let stagingPath: String
  let devicePath: String
  let blockID: String
  let directIO: Bool
  let syncMode: KrunDiskSyncMode
  var readOnly: Bool

  var diskConfig: KrunDiskConfig {
    KrunDiskConfig(
      blockID: blockID,
      path: source,
      readOnly: readOnly,
      directIO: directIO,
      syncMode: syncMode
    )
  }
}

enum KrunVolumeLayout {
  static func attachments(for config: ContainerConfiguration) throws -> [KrunVolumeAttachment] {
    var attachments: [KrunVolumeAttachment] = []
    var indexByName: [String: Int] = [:]

    for filesystem in config.mounts {
      guard case .volume(let name, let format, let cache, let sync) = filesystem.type else {
        continue
      }
      guard format == "ext4" else {
        throw KrunFeatureGate.unsupported("non-ext4 volume mounts")
      }

      let directIO = directIO(for: cache)
      let syncMode = syncMode(for: sync)
      let readOnly = filesystem.options.contains("ro")

      if let existingIndex = indexByName[name] {
        let existing = attachments[existingIndex]
        guard existing.source == filesystem.source,
          existing.directIO == directIO,
          existing.syncMode == syncMode
        else {
          throw ContainerizationError(
            .invalidArgument,
            message: "volume \(name) resolves to inconsistent block-device configuration"
          )
        }
        if !readOnly {
          attachments[existingIndex].readOnly = false
        }
        continue
      }

      guard attachments.count < KrunDefaults.maxVolumeCount else {
        throw ContainerizationError(
          .invalidArgument,
          message: "container-runtime-krun supports at most \(KrunDefaults.maxVolumeCount) attached volumes"
        )
      }

      let index = attachments.count
      indexByName[name] = index
      attachments.append(
        KrunVolumeAttachment(
          name: name,
          source: filesystem.source,
          stagingPath: stagingPath(containerID: config.id, index: index),
          devicePath: devicePath(index: index),
          blockID: "volume\(index)",
          directIO: directIO,
          syncMode: syncMode,
          readOnly: readOnly
        )
      )
    }

    return attachments
  }

  static func ociMounts(
    for config: ContainerConfiguration,
    attachments: [KrunVolumeAttachment]
  ) throws -> [ContainerizationOCI.Mount] {
    let byName = Dictionary(uniqueKeysWithValues: attachments.map { ($0.name, $0) })
    var mounts: [ContainerizationOCI.Mount] = []
    mounts.reserveCapacity(config.mounts.count)

    for filesystem in config.mounts {
      switch filesystem.type {
      case .tmpfs:
        mounts.append(
          .init(
            type: "tmpfs",
            source: "tmpfs",
            destination: filesystem.destination,
            options: filesystem.options
          )
        )
      case .volume(let name, _, _, _):
        guard let attachment = byName[name] else {
          throw ContainerizationError(
            .internalError,
            message: "missing prepared volume attachment for \(name)"
          )
        }
        mounts.append(
          .init(
            type: "none",
            source: attachment.stagingPath,
            destination: filesystem.destination,
            options: ["bind"] + filesystem.options
          )
        )
      case .virtiofs:
        // Host shares are prepared independently by KrunVirtioFSLayout.
        continue
      case .block:
        throw KrunFeatureGate.unsupported("direct block-device mounts")
      }
    }

    return mounts
  }

  private static func stagingPath(containerID: String, index: Int) -> String {
    "/run/container/\(containerID)/volumes/\(index)"
  }

  private static func devicePath(index: Int) -> String {
    // initfs and rootfs occupy vda and vdb respectively.
    let scalar = UnicodeScalar(Int(Character("c").asciiValue!) + index)!
    return "/dev/vd\(Character(scalar))"
  }

  private static func directIO(for cache: Filesystem.CacheMode) -> Bool {
    switch cache {
    case .off: true
    case .on, .auto: false
    }
  }

  private static func syncMode(for sync: Filesystem.SyncMode) -> KrunDiskSyncMode {
    switch sync {
    case .nosync: .none
    case .fsync: .relaxed
    case .full: .full
    }
  }
}
