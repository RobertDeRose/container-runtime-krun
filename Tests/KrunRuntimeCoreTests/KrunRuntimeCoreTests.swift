import ContainerResource
import Darwin
import ContainerizationOCI
import Foundation
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

@Test func copyPortPoolRotatesReleasedMappings() async throws {
  let entries = (0..<3).map { index in
    KrunSocketLayout.IOEntry(port: UInt32(index), path: "/tmp/copy-\(index)")
  }
  let pool = KrunPortPool(entries: entries, name: "copy", rotateReleased: true)

  let first = try await pool.take(1)
  #expect(first.map(\.port) == [0])
  await pool.put(first)

  let second = try await pool.take(1)
  #expect(second.map(\.port) == [1])
  await pool.put(second)

  let third = try await pool.take(1)
  #expect(third.map(\.port) == [2])
  await pool.put(third)

  let wrapped = try await pool.take(1)
  #expect(wrapped.map(\.port) == [0])
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

@Test func featureGateAllowsMultipleAllocationOnlyNetworkConfigurations() throws {
  let image = ImageDescription(
    reference: "example.invalid/test:latest",
    descriptor: Descriptor(
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: "sha256:" + String(repeating: "4", count: 64),
      size: 0
    )
  )
  let process = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
  var container = ContainerConfiguration(id: "multi-network", image: image, process: process)
  container.networks = [
    AttachmentConfiguration(network: "net-a", options: AttachmentOptions(hostname: "multi-network")),
    AttachmentConfiguration(network: "net-b", options: AttachmentOptions(hostname: "multi-network")),
  ]

  try KrunFeatureGate.validate(container)
}

@Test func copyBytesHonorsKnownPayloadLength() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let source = directory.appendingPathComponent("source.bin")
  let destination = directory.appendingPathComponent("destination.bin")
  try Data("payloadtrailing".utf8).write(to: source)
  _ = FileManager.default.createFile(atPath: destination.path, contents: Data())

  let sourceHandle = try FileHandle(forReadingFrom: source)
  let destinationHandle = try FileHandle(forWritingTo: destination)
  defer {
    try? sourceHandle.close()
    try? destinationHandle.close()
  }

  try KrunCopyTransfer.copyBytes(
    from: sourceHandle.fileDescriptor,
    to: destinationHandle.fileDescriptor,
    chunkSize: 3,
    operation: "test",
    byteCount: 7
  )

  #expect(try Data(contentsOf: destination) == Data("payload".utf8))
}

@Test func copyBytesRejectsEarlyEOFForKnownPayloadLength() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let source = directory.appendingPathComponent("source.bin")
  let destination = directory.appendingPathComponent("destination.bin")
  try Data("short".utf8).write(to: source)
  _ = FileManager.default.createFile(atPath: destination.path, contents: Data())

  let sourceHandle = try FileHandle(forReadingFrom: source)
  let destinationHandle = try FileHandle(forWritingTo: destination)
  defer {
    try? sourceHandle.close()
    try? destinationHandle.close()
  }

  var rejected = false
  do {
    try KrunCopyTransfer.copyBytes(
      from: sourceHandle.fileDescriptor,
      to: destinationHandle.fileDescriptor,
      chunkSize: 3,
      operation: "test",
      byteCount: 6
    )
  } catch {
    rejected = true
  }
  #expect(rejected)
}

@Test func copyInputFinishHalfClosesTheWriteSide() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let source = directory.appendingPathComponent("source.bin")
  try Data("payload".utf8).write(to: source)

  var descriptors = [Int32](repeating: -1, count: 2)
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
  let sender = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
  let receiver = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
  defer {
    try? sender.close()
    try? receiver.close()
  }

  try await KrunCopyTransfer.send(
    source: source,
    isArchive: false,
    to: sender,
    chunkSize: 3
  )

  var payload = [UInt8](repeating: 0, count: 7)
  let received = read(receiver.fileDescriptor, &payload, payload.count)
  #expect(received == payload.count)
  #expect(Data(payload) == Data("payload".utf8))

  var eofByte: UInt8 = 0
  #expect(read(receiver.fileDescriptor, &eofByte, 1) == 0)

  let reply = Data("x".utf8)
  let replyCount = reply.withUnsafeBytes { buffer in
    write(receiver.fileDescriptor, buffer.baseAddress, buffer.count)
  }
  #expect(replyCount == 1)

  var response: UInt8 = 0
  #expect(read(sender.fileDescriptor, &response, 1) == 1)
  #expect(response == 120)
}

@Test func copyOutMetadataValidationRejectsChangedSource() throws {
  try KrunCopyOperations.validateCopyOutMetadata(
    isArchive: false,
    totalSize: 1024,
    expectedArchive: false,
    expectedSize: 1024
  )

  var typeMismatchRejected = false
  do {
    try KrunCopyOperations.validateCopyOutMetadata(
      isArchive: true,
      totalSize: 0,
      expectedArchive: false,
      expectedSize: 1024
    )
  } catch {
    typeMismatchRejected = true
  }
  #expect(typeMismatchRejected)

  var sizeMismatchRejected = false
  do {
    try KrunCopyOperations.validateCopyOutMetadata(
      isArchive: false,
      totalSize: 2048,
      expectedArchive: false,
      expectedSize: 1024
    )
  } catch {
    sizeMismatchRejected = true
  }
  #expect(sizeMismatchRejected)
}
