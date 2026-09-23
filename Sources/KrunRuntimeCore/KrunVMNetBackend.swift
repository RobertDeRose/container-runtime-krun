import ContainerResource
import ContainerizationError
import Foundation
import KrunVMMProtocol

/// Translate an Apple-owned attachment into native libkrun configuration.
/// No network allocation, packet helper, or second IPAM lives in the runtime.
public enum KrunVMNetBackend {
  public static func configuration(for attachment: Attachment) throws -> KrunNetworkConfig {
    #if !os(macOS)
      throw KrunFeatureGate.unsupported("networking outside macOS")
    #else
      guard #available(macOS 26, *) else {
        throw KrunFeatureGate.unsupported("native vmnet on macOS versions older than 26")
      }
      guard let macAddress = attachment.macAddress else {
        throw ContainerizationError(
          .invalidState,
          message: "network attachment \(attachment.network) does not have a MAC address"
        )
      }
      switch attachment.variant {
      case "allocationOnly":
        return KrunNetworkConfig(
          ipv4Gateway: attachment.ipv4Gateway.description,
          ipv4Mask: ipv4String(attachment.ipv4Address.prefix.prefixMask32),
          macAddress: macAddress.bytes
        )
      case "reserved":
        throw ContainerizationError(
          .unsupported,
          message: "network \(attachment.network) is incompatible with native libkrun vmnet; "
            + "use container-network-vmnet with variant=allocationOnly"
        )
      default:
        throw KrunFeatureGate.unsupported("network variant \(attachment.variant ?? "unknown")")
      }
    #endif
  }

  private static func ipv4String(_ value: UInt32) -> String {
    [24, 16, 8, 0].map { String((value >> $0) & 0xff) }.joined(separator: ".")
  }
}
