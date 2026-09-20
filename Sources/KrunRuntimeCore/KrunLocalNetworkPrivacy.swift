// Derived from apple/container's ContainerOS.LocalNetworkPrivacy implementation.
// Apple Inc. and the container project authors license that source under Apache-2.0.
#if os(macOS)
  import Darwin

  /// Best-effort trigger for macOS Local Network Privacy before a published-port
  /// forwarder connects to the guest's vmnet address.
  ///
  /// This follows Apple's TN3179 technique and the implementation used by
  /// container-runtime-linux: connect UDP sockets to randomized IPv6 link-local
  /// peers without sending traffic. macOS can then present the Local Network
  /// permission prompt for this runtime before SocketForwarder opens its backend.
  enum KrunLocalNetworkPrivacy {
    @discardableResult
    static func trigger() -> Int {
      let addresses = selectedLinkLocalIPv6Addresses()
      var attempted = 0

      for address in addresses {
        let socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { break }
        defer { close(socketFD) }

        withUnsafePointer(to: address) { addressPointer in
          addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            _ = connect(socketFD, socketAddress, socklen_t(socketAddress.pointee.sa_len))
          }
        }
        attempted += 1
      }

      return attempted
    }

    private static func selectedLinkLocalIPv6Addresses() -> [sockaddr_in6] {
      let firstHost = (0..<8).map { _ in UInt8.random(in: 0...255) }
      let secondHost = (0..<8).map { _ in UInt8.random(in: 0...255) }

      return Array(
        ipv6AddressesOfBroadcastCapableInterfaces()
          .filter { isIPv6AddressLinkLocal($0) }
          .map { address in
            var address = address
            address.sin6_port = UInt16(9).bigEndian
            return address
          }
          .map { address in
            [
              setIPv6LinkLocalAddressHostPart(of: address, to: firstHost),
              setIPv6LinkLocalAddressHostPart(of: address, to: secondHost),
            ]
          }
          .joined()
      )
    }

    private static func setIPv6LinkLocalAddressHostPart(
      of address: sockaddr_in6,
      to hostPart: [UInt8]
    ) -> sockaddr_in6 {
      precondition(hostPart.count == 8)
      var result = address
      withUnsafeMutableBytes(of: &result.sin6_addr) { buffer in
        buffer[8...].copyBytes(from: hostPart)
      }
      return result
    }

    private static func isIPv6AddressLinkLocal(_ address: sockaddr_in6) -> Bool {
      address.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe
        && (address.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
    }

    private static func ipv6AddressesOfBroadcastCapableInterfaces() -> [sockaddr_in6] {
      var addressList: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&addressList) == 0, let start = addressList else { return [] }
      defer { freeifaddrs(start) }

      return sequence(first: start, next: { $0.pointee.ifa_next })
        .compactMap { interface -> sockaddr_in6? in
          guard
            (interface.pointee.ifa_flags & UInt32(bitPattern: IFF_BROADCAST)) != 0,
            let address = interface.pointee.ifa_addr,
            address.pointee.sa_family == AF_INET6,
            address.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size
          else {
            return nil
          }
          return UnsafeRawPointer(address).load(as: sockaddr_in6.self)
        }
    }
  }
#else
  enum KrunLocalNetworkPrivacy {
    @discardableResult
    static func trigger() -> Int { 0 }
  }
#endif
