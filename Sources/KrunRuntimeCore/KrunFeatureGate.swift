import ContainerResource
import ContainerizationError

public enum KrunFeatureGate {
  public static func validate(_ config: ContainerConfiguration) throws {
    if config.networks.count > 1 {
      throw unsupported("multiple network attachments")
    }
    if !config.publishedPorts.isEmpty && config.networks.isEmpty {
      throw unsupported("published TCP/UDP ports without a network attachment")
    }
    if !config.publishedSockets.isEmpty {
      throw unsupported("published Unix sockets")
    }
    if config.rosetta {
      throw ContainerizationError(
        .unsupported,
        message:
          "container-runtime-krun does not support Rosetta; use Apple's official runtime for x86_64 emulation"
      )
    }
    if config.virtualization {
      throw unsupported("nested virtualization")
    }
    if config.ssh {
      throw unsupported("SSH agent forwarding")
    }
    if config.useInit {
      throw unsupported("--init")
    }
    for mount in config.mounts {
      switch mount.type {
      case .tmpfs:
        break
      case .volume(_, let format, _, _):
        if format != "ext4" {
          throw unsupported("non-ext4 volume mounts")
        }
      case .block, .virtiofs:
        throw unsupported("host, block, and virtiofs mounts")
      }
    }
  }

  public static func unsupported(_ feature: String) -> ContainerizationError {
    ContainerizationError(
      .unsupported,
      message: "container-runtime-krun does not support \(feature)"
    )
  }
}
