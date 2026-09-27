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
  #expect(network.backend == .nativeVMNetShared)
  #expect(network.socketPath == nil)
  #expect(network.features == 0)
  #expect(network.flags == 0)
}

@Test func unixgramNetworkConfigRoundTrips() throws {
  let network = KrunNetworkConfig(
    backend: .unixgram,
    ipv4Gateway: "192.168.200.1",
    ipv4Mask: "255.255.255.0",
    socketPath: "/tmp/vmnet-helper.sock",
    macAddress: [2, 0, 0, 0, 0, 2],
    features: KrunNetworkFeatures.unixgramCompatOffload
  )
  let decoded = try JSONDecoder().decode(
    KrunNetworkConfig.self, from: JSONEncoder().encode(network)
  )
  #expect(decoded == network)
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
  #expect(KrunNetworkFeatures.nativeVMNetTCPOffload == 6531)
  #expect(KrunNetworkFeatures.unixgramCompatOffload == 19587)
  let network = KrunNetworkConfig(
    ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0",
    macAddress: [2, 0, 0, 0, 0, 1],
    features: KrunNetworkFeatures.nativeVMNetTCPOffload
  )
  try network.validateNativeVMNet()
  let data = try JSONEncoder().encode(network)
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["socketPath"] == nil)
}

@Test func nativeVMNetRejectsUnixgramBackend() {
  let network = KrunNetworkConfig(
    backend: .unixgram,
    ipv4Gateway: "192.168.200.1",
    ipv4Mask: "255.255.255.0",
    socketPath: "/tmp/vmnet-helper.sock",
    macAddress: [2, 0, 0, 0, 0, 1]
  )
  #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
}

@Test func nativeVMNetRejectsInvalidMACAndPartialOffloads() {
  for mac: [UInt8] in [[], [2, 0], [0, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 1]] {
    let network = KrunNetworkConfig(
      ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0", macAddress: mac
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
  for (features, flags): (UInt32, UInt32) in [
    (1, 0), (1 << 11, 0),
    (KrunNetworkFeatures.nativeVMNetTCPOffload, 1),
  ] {
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

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Test func vmmControlChannelUsesStreamSocketPair() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  defer {
    try? pair.runtime.close()
    try? pair.helper.close()
  }

  for handle in [pair.runtime, pair.helper] {
    var socketType: Int32 = 0
    var length = socklen_t(MemoryLayout.size(ofValue: socketType))
    #expect(
      getsockopt(
        handle.fileDescriptor, SOL_SOCKET, SO_TYPE, &socketType, &length
      ) == 0
    )
    #expect(socketType == SOCK_STREAM)
  }
}

@Test func vmmControlChannelCanBackProcessStandardInput() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  let output = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/cat")
  process.standardInput = pair.helper
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice

  try process.run()
  try pair.helper.close()
  let payload = Data("control-stream\n".utf8)
  try pair.runtime.write(contentsOf: payload)
  #expect(shutdown(pair.runtime.fileDescriptor, SHUT_WR) == 0)
  process.waitUntilExit()

  let echoed = output.fileHandleForReading.readDataToEndOfFile()
  #expect(process.terminationStatus == 0)
  #expect(echoed == payload)
  try pair.runtime.close()
}

@Test func vmmControlChannelTransfersDialFileDescriptor() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  defer {
    try? pair.runtime.close()
    try? pair.helper.close()
  }

  try KrunVMMControlChannel.sendDialRequest(to: pair.runtime.fileDescriptor, port: 43210)
  #expect(
    try KrunVMMControlChannel.receiveRequest(from: pair.helper.fileDescriptor)
      == .dial(port: 43210)
  )

  let sourceFD = open("/dev/null", O_RDONLY)
  #expect(sourceFD >= 0)
  defer { close(sourceFD) }
  try KrunVMMControlChannel.sendDialResponse(
    to: pair.helper.fileDescriptor,
    result: 0,
    connectedFD: sourceFD
  )
  let received = try KrunVMMControlChannel.receiveDialResponse(from: pair.runtime.fileDescriptor)
  defer { try? received.close() }
  #expect(fcntl(received.fileDescriptor, F_GETFD) >= 0)
}

@Test func vmmControlChannelPreservesDialErrno() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  defer {
    try? pair.runtime.close()
    try? pair.helper.close()
  }

  try KrunVMMControlChannel.sendDialResponse(
    to: pair.helper.fileDescriptor,
    result: -ECONNREFUSED,
    connectedFD: nil
  )
  do {
    _ = try KrunVMMControlChannel.receiveDialResponse(from: pair.runtime.fileDescriptor)
    Issue.record("expected ECONNREFUSED")
  } catch let error as POSIXError {
    #expect(error.code == .ECONNREFUSED)
  }
}
