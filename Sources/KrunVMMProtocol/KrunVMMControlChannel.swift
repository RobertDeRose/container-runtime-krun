import Foundation
import KrunVMMIPC

public enum KrunVMMControlRequest: Sendable, Equatable {
  case dial(port: UInt32)
}

public enum KrunVMMControlError: Error, CustomStringConvertible, Sendable {
  case unknownOpcode(UInt32)
  case invalidStatus(Int32)
  case operationFailed(Int32)

  public var description: String {
    switch self {
    case .unknownOpcode(let opcode):
      return "unknown VMM control opcode \(opcode)"
    case .invalidStatus(let status):
      return "invalid VMM control response status \(status)"
    case .operationFailed(let result):
      return "VMM control operation failed with result \(result)"
    }
  }
}

public enum KrunVMMControlChannel {
  private static let dialOpcode: UInt32 = 1

  public static func makeSocketPair() throws -> (runtime: FileHandle, helper: FileHandle) {
    var descriptors: [Int32] = [-1, -1]
    let result = descriptors.withUnsafeMutableBufferPointer { buffer in
      krun_vmm_ipc_socketpair(buffer.baseAddress)
    }
    try check(result)
    return (
      FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
      FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
  }

  public static func sendDialRequest(to fd: Int32, port: UInt32) throws {
    try check(krun_vmm_ipc_send_request(fd, dialOpcode, port))
  }

  public static func receiveRequest(from fd: Int32) throws -> KrunVMMControlRequest? {
    var opcode: UInt32 = 0
    var port: UInt32 = 0
    let result = krun_vmm_ipc_recv_request(fd, &opcode, &port)
    if result == 0 {
      return nil
    }
    try check(result < 0 ? result : 0)
    guard opcode == dialOpcode else {
      throw KrunVMMControlError.unknownOpcode(opcode)
    }
    return .dial(port: port)
  }

  public static func sendDialResponse(
    to fd: Int32,
    result: Int32,
    connectedFD: Int32?
  ) throws {
    guard result <= 0 else {
      throw KrunVMMControlError.invalidStatus(result)
    }
    try check(krun_vmm_ipc_send_response(fd, result, connectedFD ?? -1))
  }

  public static func receiveDialResponse(from fd: Int32) throws -> FileHandle {
    var status: Int32 = 0
    var connectedFD: Int32 = -1
    try check(krun_vmm_ipc_recv_response(fd, &status, &connectedFD))
    guard status <= 0 else {
      if connectedFD >= 0 {
        try? FileHandle(fileDescriptor: connectedFD, closeOnDealloc: true).close()
      }
      throw KrunVMMControlError.invalidStatus(status)
    }
    if status < 0 {
      if let code = POSIXErrorCode(rawValue: -status) {
        throw POSIXError(code)
      }
      throw KrunVMMControlError.operationFailed(status)
    }
    return FileHandle(fileDescriptor: connectedFD, closeOnDealloc: true)
  }

  private static func check(_ result: Int32) throws {
    guard result < 0 else { return }
    if let code = POSIXErrorCode(rawValue: -result) {
      throw POSIXError(code)
    }
    throw KrunVMMControlError.operationFailed(result)
  }
}
