import Foundation

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

  public init(
    libkrun: String,
    kernel: String,
    initDisk: String,
    rootDisk: String,
    commandLine: String,
    bootLog: String,
    cpus: UInt8,
    memoryMiB: UInt32,
    vsockMappings: [KrunVsockMapping]
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
  }
}

public enum KrunDefaults {
  public static let controlPort: UInt32 = 1024
  public static let firstIOPort: UInt32 = 0x1000_0000
  public static let ioPortCount = 96
  public static let memoryOverheadBytes: UInt64 = 128 * 1024 * 1024

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
