import Foundation
import Testing

@testable import KrunVMMProtocol

@Test func configurationRoundTrips() throws {
  let original = KrunVMMConfig(
    libkrun: "/opt/container/libexec/container-plugins/container-runtime-krun/lib/libkrun.dylib",
    kernel: "/tmp/kernel",
    initDisk: "/tmp/init.ext4",
    rootDisk: "/tmp/root.ext4",
    commandLine: "console=hvc0 init=/sbin/vminitd ro root=/dev/vda",
    bootLog: "/tmp/boot.log",
    cpus: 3,
    memoryMiB: 1152,
    vsockMappings: [
      .init(port: 1024, path: "/tmp/vminit", listen: true),
      .init(port: 0x1000_0000, path: "/tmp/p00", listen: false),
    ],
    networks: [
      .init(
        ipv4Gateway: "192.168.200.1",
        ipv4Mask: "255.255.255.0",
        macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
      )
    ],
    disks: [
      .init(
        blockID: "volume0",
        path: "/tmp/volume.ext4",
        readOnly: false
      )
    ],
    virtioFS: [
      .init(
        tag: "krunfs0",
        path: "/tmp/share",
        readOnly: true
      )
    ]
  )
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(KrunVMMConfig.self, from: data)
  #expect(decoded == original)
}

@Test func networkConfigDefaultsToNoOffloadFlags() {
  let network = KrunNetworkConfig(
    ipv4Gateway: "192.168.200.1",
    ipv4Mask: "255.255.255.0",
    macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
  )
  #expect(network.features == 0)
  #expect(network.flags == 0)
}

@Test func defaultsReserveControlAndStdioSeparately() {
  #expect(KrunDefaults.controlPort < KrunDefaults.firstIOPort)
  #expect(KrunDefaults.ioPortCount >= 3)
}

@Test func bundledLibkrunPathIsRelativeToPluginExecutable() {
  let executable = URL(
    fileURLWithPath:
      "/opt/container/libexec/container-plugins/container-runtime-krun/bin/container-runtime-krun"
  )
  #expect(
    KrunDefaults.bundledLibkrunPath(executableURL: executable)
      == "/opt/container/libexec/container-plugins/container-runtime-krun/lib/libkrun.dylib"
  )
}

@Test func nativeVMNetAcceptsBoundedStaticConfiguration() throws {
  let network = KrunNetworkConfig(
    ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0",
    macAddress: [2, 0, 0, 0, 0, 1]
  )
  try network.validateNativeVMNet()
  let data = try JSONEncoder().encode(network)
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["socketPath"] == nil)
}

@Test func nativeVMNetRejectsInvalidMACAndOffloads() {
  for mac: [UInt8] in [[], [2, 0], [0, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 1]] {
    let network = KrunNetworkConfig(
      ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0", macAddress: mac
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
  for (features, flags): (UInt32, UInt32) in [(1, 0), (0, 1)] {
    let network = KrunNetworkConfig(
      ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0",
      macAddress: [2, 0, 0, 0, 0, 1], features: features, flags: flags
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
}

@Test func nativeVMNetRejectsControlCharactersAndOversizedAddresses() {
  for gateway in [
    "192.168.1.1\u{0}evil", "192.168.1.1\n", "[::1]", String(repeating: "1", count: 16),
  ] {
    let network = KrunNetworkConfig(
      ipv4Gateway: gateway, ipv4Mask: "255.255.255.0", macAddress: [2, 0, 0, 0, 0, 1]
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
}
