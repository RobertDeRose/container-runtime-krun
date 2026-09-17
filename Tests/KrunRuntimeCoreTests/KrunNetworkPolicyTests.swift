import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Testing

@testable import KrunRuntimeCore

@Test func managedDefaultNetworkUsesFirstAvailableSubnet() throws {
  let defaultNetwork = try makeNetwork(
    name: "default",
    variant: "reserved",
    subnet: "192.168.64.0/24"
  )

  let configuration = try KrunNetworkPolicy.managedDefaultConfiguration(existing: [defaultNetwork])

  #expect(configuration.name == "krun")
  #expect(configuration.mode == .nat)
  #expect(configuration.plugin == "container-network-vmnet")
  #expect(configuration.options["variant"] == "allocationOnly")
  #expect(configuration.ipv4Subnet?.description == "192.168.200.0/24")
}

@Test func managedDefaultNetworkSkipsOverlappingSubnets() throws {
  let existing = try makeNetwork(
    name: "existing",
    variant: "allocationOnly",
    subnet: "192.168.200.0/23"
  )

  let configuration = try KrunNetworkPolicy.managedDefaultConfiguration(existing: [existing])

  #expect(configuration.ipv4Subnet?.description == "192.168.202.0/24")
}

@Test func compatibleAllocationOnlyNetworkIsAccepted() throws {
  let network = try makeNetwork(
    name: "custom",
    variant: "allocationOnly",
    subnet: "192.168.220.0/24"
  )

  try KrunNetworkPolicy.validateCompatible(network)
}

@Test func reservedNetworkIsRejectedWithActionableError() throws {
  let network = try makeNetwork(
    name: "custom",
    variant: "reserved",
    subnet: "192.168.220.0/24"
  )

  do {
    try KrunNetworkPolicy.validateCompatible(network)
    Issue.record("expected reserved network to be rejected")
  } catch let error as ContainerizationError {
    #expect(error.code == .unsupported)
    #expect(error.message.contains("network custom is incompatible"))
    #expect(error.message.contains("variant reserved"))
  }
}

@Test func hostOnlyNetworkIsRejectedWithActionableError() throws {
  let network = try makeNetwork(
    name: "custom",
    mode: .hostOnly,
    variant: "allocationOnly",
    subnet: "192.168.220.0/24"
  )

  do {
    try KrunNetworkPolicy.validateCompatible(network)
    Issue.record("expected host-only network to be rejected")
  } catch let error as ContainerizationError {
    #expect(error.code == .unsupported)
    #expect(error.message.contains("mode hostOnly"))
  }
}

@Test func nonVmnetNetworkIsRejectedWithActionableError() throws {
  let network = try makeNetwork(
    name: "custom",
    plugin: "example-network-plugin",
    variant: "allocationOnly",
    subnet: "192.168.220.0/24"
  )

  do {
    try KrunNetworkPolicy.validateCompatible(network)
    Issue.record("expected non-vmnet network to be rejected")
  } catch let error as ContainerizationError {
    #expect(error.code == .unsupported)
    #expect(error.message.contains("plugin example-network-plugin"))
  }
}

private func makeNetwork(
  name: String,
  plugin: String = "container-network-vmnet",
  mode: NetworkMode = .nat,
  variant: String,
  subnet: String
) throws -> NetworkResource {
  let cidr = try CIDRv4(subnet)
  return NetworkResource(
    configuration: try NetworkConfiguration(
      name: name,
      mode: mode,
      ipv4Subnet: cidr,
      plugin: plugin,
      options: ["variant": variant]
    ),
    status: NetworkStatus(
      ipv4Subnet: cidr,
      ipv4Gateway: IPv4Address(cidr.lower.value + 1),
      ipv6Subnet: nil
    )
  )
}
