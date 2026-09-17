import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import KrunRuntimeCore

private func virtioFSTestContainer(id: String) -> ContainerConfiguration {
  let image = ImageDescription(
    reference: "example.invalid/test:latest",
    descriptor: Descriptor(
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: "sha256:" + String(repeating: "a", count: 64),
      size: 0
    )
  )
  let process = ProcessConfiguration(
    executable: "/bin/sh",
    arguments: ["-c", "true"],
    environment: []
  )
  return ContainerConfiguration(id: id, image: image, process: process)
}

@Test func virtioFSLayoutMapsReadWriteAndReadOnlyShares() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let readWrite = base.appendingPathComponent("rw")
  let readOnly = base.appendingPathComponent("ro")
  try FileManager.default.createDirectory(at: readWrite, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }

  var container = virtioFSTestContainer(id: "virtiofs-layout")
  container.mounts = [
    .virtiofs(source: readWrite.path, destination: "/mnt/rw", options: []),
    .virtiofs(source: readOnly.path, destination: "/mnt/ro", options: ["ro"]),
  ]

  try KrunFeatureGate.validate(container)
  let shares = try KrunVirtioFSLayout.shares(for: container)

  #expect(shares.count == 2)
  #expect(shares[0].tag == "krunfs0")
  #expect(shares[0].hostPath == readWrite.resolvingSymlinksInPath().path)
  #expect(shares[0].stagingPath == "/run/container/virtiofs-layout/virtiofs/0")
  #expect(shares[0].destination == "/mnt/rw")
  #expect(!shares[0].readOnly)
  #expect(shares[0].vmmConfig.semantics == .linuxSimplified)
  #expect(shares[0].guestMount.type == "virtiofs")
  #expect(shares[0].guestMount.source == "krunfs0")
  #expect(shares[0].guestMount.options.isEmpty)
  #expect(shares[0].ociMount.type == "bind")
  #expect(shares[0].ociMount.options == ["bind"])

  #expect(shares[1].tag == "krunfs1")
  #expect(shares[1].readOnly)
  #expect(shares[1].vmmConfig.readOnly)
  #expect(shares[1].guestMount.options == ["ro"])
  #expect(shares[1].ociMount.options == ["bind", "ro"])
}

@Test func specBuilderBindMountsVirtioFSStagingPaths() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var container = virtioFSTestContainer(id: "virtiofs-spec")
  container.mounts = [
    .virtiofs(source: directory.path, destination: "/workspace", options: ["ro"])
  ]
  let shares = try KrunVirtioFSLayout.shares(for: container)
  let spec = try KrunSpecBuilder.make(
    container: container,
    process: container.initProcess,
    rootPath: "/run/container/virtiofs-spec/rootfs",
    volumeAttachments: [],
    virtioFSShares: shares
  )

  let mount = spec.mounts.first { $0.destination == "/workspace" }
  #expect(mount?.type == "bind")
  #expect(mount?.source == "/run/container/virtiofs-spec/virtiofs/0")
  #expect(mount?.options == ["bind", "ro"])
}

@Test func containerPathUsesVirtioFSStagingRoot() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var container = virtioFSTestContainer(id: "virtiofs-path")
  container.mounts = [
    .virtiofs(source: directory.path, destination: "/workspace", options: ["ro"])
  ]
  let shares = try KrunVirtioFSLayout.shares(for: container)

  let resolved = KrunContainerPath.resolve(
    config: container,
    rootPath: "/run/container/virtiofs-path/rootfs",
    volumeAttachments: [],
    virtioFSShares: shares,
    path: URL(filePath: "/workspace/subdir/file.txt")
  )

  #expect(resolved.root == "/run/container/virtiofs-path/virtiofs/0")
  #expect(resolved.path == "/subdir/file.txt")
  #expect(resolved.readOnly)
}

@Test func virtioFSLayoutRejectsMissingHostDirectory() {
  var container = virtioFSTestContainer(id: "virtiofs-missing")
  let missing = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .path
  container.mounts = [
    .virtiofs(source: missing, destination: "/workspace", options: [])
  ]

  #expect(throws: (any Error).self) {
    _ = try KrunVirtioFSLayout.shares(for: container)
  }
}