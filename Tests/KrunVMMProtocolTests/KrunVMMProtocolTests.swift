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
    ]
  )
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(KrunVMMConfig.self, from: data)
  #expect(decoded == original)
}

@Test func defaultsReserveControlAndStdioSeparately() {
  #expect(KrunDefaults.controlPort < KrunDefaults.firstIOPort)
  #expect(KrunDefaults.ioPortCount >= 3)
}
