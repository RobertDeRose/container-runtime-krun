import Foundation

public enum KrunDiskSyncMode: UInt32, Codable, Sendable, Equatable {
  case none = 0
  case relaxed = 1
  case full = 2
}

public struct KrunDiskConfig: Codable, Sendable, Equatable {
  public let blockID: String
  public let path: String
  public let readOnly: Bool
  public let directIO: Bool
  public let syncMode: KrunDiskSyncMode

  public init(
    blockID: String,
    path: String,
    readOnly: Bool,
    directIO: Bool = false,
    syncMode: KrunDiskSyncMode = .relaxed
  ) {
    self.blockID = blockID
    self.path = path
    self.readOnly = readOnly
    self.directIO = directIO
    self.syncMode = syncMode
  }
}

public struct KrunVsockMapping: Codable, Sendable, Equatable {
  public let port: UInt32
  public let path: String
  public let listen: Bool

  public init(port: UInt32, path: String, listen: Bool) {
    self.port = port
    self.path = path
    self.listen = listen
  }
}

public struct KrunNetworkConfig: Codable, Sendable, Equatable {
  public let socketPath: String
  public let macAddress: [UInt8]
  public let features: UInt32
  public let flags: UInt32

  public init(
    socketPath: String,
    macAddress: [UInt8],
    features: UInt32 = 0,
    flags: UInt32 = 0
  ) {
    self.socketPath = socketPath
    self.macAddress = macAddress
    self.features = features
    self.flags = flags
  }
}

public struct KrunVMMConfig: Codable, Sendable, Equatable {
  public let libkrun: String
  public let kernel: String
  public let initDisk: String
  public let rootDisk: String
  public let commandLine: String
  public let bootLog: String
  public let cpus: UInt8
  public let memoryMiB: UInt32
  public let vsockMappings: [KrunVsockMapping]
  public let networks: [KrunNetworkConfig]
  public let disks: [KrunDiskConfig]

  public init(
    libkrun: String,
    kernel: String,
    initDisk: String,
    rootDisk: String,
    commandLine: String,
    bootLog: String,
    cpus: UInt8,
    memoryMiB: UInt32,
    vsockMappings: [KrunVsockMapping],
    networks: [KrunNetworkConfig] = [],
    disks: [KrunDiskConfig] = []
  ) {
    self.libkrun = libkrun
    self.kernel = kernel
    self.initDisk = initDisk
    self.rootDisk = rootDisk
    self.commandLine = commandLine
    self.bootLog = bootLog
    self.cpus = cpus
    self.memoryMiB = memoryMiB
    self.vsockMappings = vsockMappings
    self.networks = networks
    self.disks = disks
  }
}

public enum KrunDefaults {
  public static let controlPort: UInt32 = 1024
  public static let firstIOPort: UInt32 = 0x1000_0000
  public static let ioPortCount = 96
  public static let firstCopyPort: UInt32 = firstIOPort + UInt32(ioPortCount)
  public static let copyPortCount = 8
  public static let firstRelayPort: UInt32 = firstCopyPort + UInt32(copyPortCount)
  public static let memoryOverheadBytes: UInt64 = 128 * 1024 * 1024
  public static let maxVolumeCount = 24

  public static var libkrunPath: String {
    if let configured = ProcessInfo.processInfo.environment["LIBKRUN_DYLIB"], !configured.isEmpty {
      return configured
    }
    for candidate in ["/opt/homebrew/lib/libkrun.dylib", "/usr/local/lib/libkrun.dylib"]
    where FileManager.default.isReadableFile(atPath: candidate) {
      return candidate
    }
    return "/opt/homebrew/lib/libkrun.dylib"
  }
}
