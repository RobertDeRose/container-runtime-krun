import ContainerResource
import ContainerizationOCI
import KrunRuntimeCore
import Testing

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
