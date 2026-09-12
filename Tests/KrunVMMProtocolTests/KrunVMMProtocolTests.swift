import Foundation
import Testing

@testable import KrunVMMProtocol

@Test func configurationRoundTrips() throws {
  let original = KrunVMMConfig(
    libkrun: "/opt/homebrew/lib/libkrun.dylib",
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
        socketPath: "/tmp/net0.sock",
        macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
      )
    ],
    disks: [
      .init(
        blockID: "volume0",
        path: "/tmp/volume.ext4",
        readOnly: false
      )
    ]
  )
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(KrunVMMConfig.self, from: data)
  #expect(decoded == original)
}

@Test func networkConfigDefaultsToNoOffloadFlags() {
  let network = KrunNetworkConfig(
    socketPath: "/tmp/net0.sock",
    macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
  )
  #expect(network.features == 0)
  #expect(network.flags == 0)
}

@Test func defaultsReserveControlAndStdioSeparately() {
  #expect(KrunDefaults.controlPort < KrunDefaults.firstIOPort)
  #expect(KrunDefaults.ioPortCount >= 3)
}
