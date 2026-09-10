import ContainerResource
import ContainerizationError

public enum KrunV01FeatureGate {
  public static func validate(_ config: ContainerConfiguration) throws {
    if !config.networks.isEmpty {
      throw unsupported("networking; use --network none with v0.1")
    }
    if !config.publishedPorts.isEmpty {
      throw unsupported("published TCP/UDP ports")
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
    for mount in config.mounts where !mount.isTmpfs {
      throw unsupported("host, block, volume, and virtiofs mounts")
    }
  }

  public static func unsupported(_ feature: String) -> ContainerizationError {
    ContainerizationError(
      .unsupported,
      message: "container-runtime-krun does not support \(feature)"
    )
  }
}
