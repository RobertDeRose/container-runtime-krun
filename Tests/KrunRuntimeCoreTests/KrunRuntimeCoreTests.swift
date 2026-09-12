import ContainerResource
import ContainerizationOCI
import KrunVMMProtocol
import SystemPackage
import Testing

@testable import KrunRuntimeCore

@Test func socketLayoutUsesShortUniquePaths() {
  let layout = KrunSocketLayout(id: "example-container")
  let guestToHostEntries = layout.ioEntries + layout.copyEntries

  #expect(layout.controlPath.utf8.count < 100)
  // Three stdio streams for each of the 32 process slots guaranteed by v0.1.
  #expect(layout.ioEntries.count == 96)
  #expect(!layout.copyEntries.isEmpty)
  #expect(Set(guestToHostEntries.map(\.port)).count == guestToHostEntries.count)
  #expect(Set(guestToHostEntries.map(\.path)).count == guestToHostEntries.count)
  #expect(guestToHostEntries.allSatisfy { $0.path.utf8.count < 100 })
  #expect(layout.mappings.count == guestToHostEntries.count + 1)
  #expect(layout.mappings.first?.listen == true)
  #expect(layout.mappings.dropFirst().allSatisfy { !$0.listen })
}

@Test func specBuilderWrapsOnlyTheInitProcess() throws {
  let image = ImageDescription(
    reference: "example.invalid/test:latest",
    descriptor: Descriptor(
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: "sha256:" + String(repeating: "0", count: 64),
      size: 0
    )
  )
  let process = ProcessConfiguration(
    executable: "/bin/sh",
    arguments: ["-c", "printf init-ok"],
    environment: []
  )
  var container = ContainerConfiguration(id: "init-test", image: image, process: process)
  container.useInit = true

  let initSpec = try KrunSpecBuilder.make(
    container: container,
    process: process,
    rootPath: "/run/container/init-test/rootfs",
    wrapWithInit: true
  )
  #expect(initSpec.process?.args == ["/.cz-init", "--", "/bin/sh", "-c", "printf init-ok"])
  let initMount = initSpec.mounts.first { $0.destination == "/.cz-init" }
  #expect(initMount?.type == "bind")
  #expect(initMount?.source == "/sbin/vminitd")
  #expect(initMount?.options == ["bind", "ro"])

  let execSpec = try KrunSpecBuilder.make(
    container: container,
    process: process,
    rootPath: "/run/container/init-test/rootfs"
  )
  #expect(execSpec.process?.args == ["/bin/sh", "-c", "printf init-ok"])
  #expect(execSpec.mounts.contains { $0.destination == "/.cz-init" } == false)
}

@Test func socketLayoutPreservesExternalRelayMappings() {
  let relays = [
    KrunVsockMapping(port: KrunDefaults.firstRelayPort, path: "/tmp/published.sock", listen: true),
    KrunVsockMapping(port: KrunDefaults.firstRelayPort + 1, path: "/tmp/agent.sock", listen: false),
  ]
  let layout = KrunSocketLayout(id: "relay-test", relayMappings: relays)

  #expect(layout.relayMappings == relays)
  #expect(Array(layout.mappings.suffix(relays.count)) == relays)
  #expect(layout.ioEntries.allSatisfy { $0.port < KrunDefaults.firstCopyPort })
  #expect(layout.copyEntries.allSatisfy { $0.port < KrunDefaults.firstRelayPort })
}

@Test func sshConfigurationIsAllowedAndInjectsTheAgentEnvironment() throws {
  let image = ImageDescription(
    reference: "example.invalid/test:latest",
    descriptor: Descriptor(
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: "sha256:" + String(repeating: "1", count: 64),
      size: 0
    )
  )
  let process = ProcessConfiguration(
    executable: "/bin/sh",
    arguments: ["-c", "true"],
    environment: []
  )
  var container = ContainerConfiguration(id: "ssh-test", image: image, process: process)
  container.ssh = true

  try KrunFeatureGate.validate(container)
  let spec = try KrunSpecBuilder.make(
    container: container,
    process: process,
    rootPath: "/run/container/ssh-test/rootfs"
  )
  #expect(spec.process?.env.contains("SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock") == true)
}

@Test func publishedUnixSocketsAreAllowedByTheFeatureGate() throws {
  let image = ImageDescription(
    reference: "example.invalid/test:latest",
    descriptor: Descriptor(
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: "sha256:" + String(repeating: "2", count: 64),
      size: 0
    )
  )
  let process = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
  var container = ContainerConfiguration(id: "socket-test", image: image, process: process)
  container.publishedSockets = [
    try PublishSocket(
      containerPath: FilePath("/run/service.sock"),
      hostPath: FilePath("/tmp/service.sock")
    )
  ]

  try KrunFeatureGate.validate(container)
}

@Test func unixSocketRelayPlanUsesFixedMappingsInBothDirections() throws {
  let image = ImageDescription(
    reference: "example.invalid/test:latest",
    descriptor: Descriptor(
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: "sha256:" + String(repeating: "3", count: 64),
      size: 0
    )
  )
  let process = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
  var container = ContainerConfiguration(id: "relay-plan", image: image, process: process)
  container.ssh = true
  container.publishedSockets = [
    try PublishSocket(
      containerPath: FilePath("/run/service.sock"),
      hostPath: FilePath("/tmp/published.sock")
    )
  ]

  let relays = try KrunUnixSocketRelays.make(
    config: container,
    dynamicEnv: ["SSH_AUTH_SOCK": "/tmp/agent.sock"],
    rootPath: "/run/container/relay-plan/rootfs",
    volumeAttachments: []
  )

  #expect(relays.count == 2)
  #expect(relays[0].port == KrunDefaults.firstRelayPort)
  #expect(relays[0].mapping.listen == true)
  #expect(relays[0].mapping.path == "/tmp/published.sock")
  #expect(
    relays[0].configuration.source.path == "/run/container/relay-plan/rootfs/run/service.sock")
  #expect(relays[0].ociMount == nil)

  #expect(relays[1].port == KrunDefaults.firstRelayPort + 1)
  #expect(relays[1].mapping.listen == false)
  #expect(relays[1].mapping.path == "/tmp/agent.sock")
  #expect(relays[1].ociMount?.destination == "/var/host-services/ssh-auth.sock")
  #expect(relays[1].ociMount?.options == ["bind"])
}
