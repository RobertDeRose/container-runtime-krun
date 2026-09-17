import ContainerResource
import ContainerizationError

public enum KrunFeatureGate {
  public static func validate(_ config: ContainerConfiguration) throws {
    if !config.publishedPorts.isEmpty && config.networks.isEmpty {
      throw unsupported("published TCP/UDP ports without a network attachment")
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
    for mount in config.mounts {
      switch mount.type {
      case .tmpfs:
        break
      case .volume(_, let format, _, _):
        if format != "ext4" {
          throw unsupported("non-ext4 volume mounts")
        }
      case .virtiofs:
        break
      case .block:
        throw unsupported("direct block-device mounts")
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
