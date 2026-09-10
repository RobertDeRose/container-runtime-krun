import Foundation
import KrunVMMProtocol

public struct KrunSocketLayout: Sendable {
  public struct IOEntry: Sendable, Hashable {
    public let port: UInt32
    public let path: String
  }

  public let directory: URL
  public let controlPath: String
  public let ioEntries: [IOEntry]

  public init(id: String) {
    let safeID = String(id.prefix(12)).replacingOccurrences(of: "/", with: "_")
    let directory = URL(
      fileURLWithPath: "/tmp/ckr-\(safeID)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    self.directory = directory
    self.controlPath = directory.appendingPathComponent("vminit").path
    self.ioEntries = (0..<KrunDefaults.ioPortCount).map { index in
      IOEntry(
        port: KrunDefaults.firstIOPort + UInt32(index),
        path: directory.appendingPathComponent(String(format: "p%02d", index)).path
      )
    }
  }

  public var mappings: [KrunVsockMapping] {
    [KrunVsockMapping(port: KrunDefaults.controlPort, path: controlPath, listen: true)]
      + ioEntries.map { KrunVsockMapping(port: $0.port, path: $0.path, listen: false) }
  }
}
