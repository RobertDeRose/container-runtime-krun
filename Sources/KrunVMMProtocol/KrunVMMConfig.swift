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

public enum KrunVirtioFSSemantics: UInt32, Codable, Sendable, Equatable {
  case linuxComplete = 0
  case linuxSimplified = 1
}

public struct KrunVirtioFSConfig: Codable, Sendable, Equatable {
  public let tag: String
  public let path: String
  public let readOnly: Bool
  public let shmSize: UInt64
  public let semantics: KrunVirtioFSSemantics

  public init(
    tag: String,
    path: String,
    readOnly: Bool,
    shmSize: UInt64 = 0,
    semantics: KrunVirtioFSSemantics = .linuxSimplified
  ) {
    self.tag = tag
    self.path = path
    self.readOnly = readOnly
    self.shmSize = shmSize
    self.semantics = semantics
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
  public let ipv4Gateway: String
  public let ipv4Mask: String
  public let macAddress: [UInt8]
  public let features: UInt32
  public let flags: UInt32

  public init(
    ipv4Gateway: String,
    ipv4Mask: String,
    macAddress: [UInt8],
    features: UInt32 = 0,
    flags: UInt32 = 0
  ) {
    self.ipv4Gateway = ipv4Gateway
    self.ipv4Mask = ipv4Mask
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
  public let virtioFS: [KrunVirtioFSConfig]

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
    disks: [KrunDiskConfig] = [],
    virtioFS: [KrunVirtioFSConfig] = []
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
    self.virtioFS = virtioFS
  }
}

public enum KrunDefaults {
  // Fixed, root-owned installation; never derive privileged code paths from an
  // environment variable, the user-controlled VM configuration, or PATH.
  public static let nativeInstallDirectory =
    "/Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun"
  public static let nativeHelperPath = nativeInstallDirectory + "/bin/container-krun-vmm-helper"
  public static let nativeLibkrunPath = nativeInstallDirectory + "/lib/libkrun.dylib"

  public static let controlPort: UInt32 = 1024
  public static let firstIOPort: UInt32 = 0x1000_0000
  public static let ioPortCount = 96
  public static let firstCopyPort: UInt32 = firstIOPort + UInt32(ioPortCount)
  public static let copyPortCount = 8
  public static let firstRelayPort: UInt32 = firstCopyPort + UInt32(copyPortCount)
  public static let memoryOverheadBytes: UInt64 = 128 * 1024 * 1024
  public static let maxVolumeCount = 24

  static func bundledLibkrunPath(executableURL: URL) -> String {
    executableURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("lib", isDirectory: true)
      .appendingPathComponent("libkrun.dylib")
      .path
  }

  public static var libkrunPath: String {
    if let configured = ProcessInfo.processInfo.environment["LIBKRUN_DYLIB"], !configured.isEmpty {
      return configured
    }
    let executableURL = Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return bundledLibkrunPath(executableURL: executableURL)
  }
}
