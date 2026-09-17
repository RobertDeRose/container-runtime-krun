import ContainerResource
import ContainerizationError
import ContainerizationExtras

enum KrunNetworkPolicy {
  static let managedDefaultNetworkName = "krun"
  static let supportedPlugin = "container-network-vmnet"
  static let supportedVariant = "allocationOnly"

  static func managedDefaultConfiguration(existing networks: [NetworkResource]) throws
    -> NetworkConfiguration
  {
    try NetworkConfiguration(
      name: managedDefaultNetworkName,
      mode: .nat,
      ipv4Subnet: nextAvailableSubnet(existing: networks),
      plugin: supportedPlugin,
      options: ["variant": supportedVariant]
    )
  }

  static func validateCompatible(_ network: NetworkResource) throws {
    let configuration = network.configuration
    let variant = configuration.options["variant"]
    guard configuration.plugin == supportedPlugin,
      configuration.mode == .nat,
      variant == supportedVariant
    else {
      throw ContainerizationError(
        .unsupported,
        message:
          "network \(network.id) is incompatible with container-runtime-krun; expected plugin "
          + "\(supportedPlugin), mode nat, and option variant=\(supportedVariant) "
          + "(found plugin \(configuration.plugin), mode \(configuration.mode.rawValue), "
          + "variant \(variant ?? "default"))"
      )
    }
  }

  static func nextAvailableSubnet(existing networks: [NetworkResource]) throws -> CIDRv4 {
    let existingSubnets = networks.map(\.status.ipv4Subnet)
    for thirdOctet in 200...254 {
      let candidate = try CIDRv4("192.168.\(thirdOctet).0/24")
      if existingSubnets.allSatisfy({ !overlaps(candidate, $0) }) {
        return candidate
      }
    }
    throw ContainerizationError(
      .invalidState,
      message:
        "container-runtime-krun could not find an unused managed network subnet in "
        + "192.168.200.0/24 through 192.168.254.0/24"
    )
  }

  private static func overlaps(_ lhs: CIDRv4, _ rhs: CIDRv4) -> Bool {
    lhs.contains(rhs.lower)
      || lhs.contains(rhs.upper)
      || rhs.contains(lhs.lower)
      || rhs.contains(lhs.upper)
  }
}
