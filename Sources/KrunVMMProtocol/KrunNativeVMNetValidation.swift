import Foundation

public struct KrunNativeVMNetError: Error, CustomStringConvertible {
  public let description: String
}

extension KrunNetworkConfig {
  /// Check the bounded ABI inputs before privileged libkrun setup. libkrun also
  /// validates the IPv4 subnet and rejects nonzero offload/DHCP options.
  public func validateNativeVMNet() throws {
    guard macAddress.count == 6, macAddress != [UInt8](repeating: 0, count: 6),
      macAddress[0] & 1 == 0
    else {
      throw KrunNativeVMNetError(description: "native vmnet requires a six-byte unicast MAC")
    }
    guard features == 0, flags == 0 else {
      throw KrunNativeVMNetError(description: "native vmnet requires features=0 and flags=0")
    }
    for value in [ipv4Gateway, ipv4Mask] {
      guard (7...15).contains(value.utf8.count),
        value.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) })
      else {
        throw KrunNativeVMNetError(
          description: "native vmnet gateway and mask must be dotted-decimal IPv4 strings")
      }
    }
  }
}
