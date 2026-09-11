import Foundation
import KrunVMMProtocol

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private struct KrunError: Error, CustomStringConvertible {
  let description: String
}

private final class KrunLibrary {
  typealias InitLog = @convention(c) (Int32, UInt32, UInt32, UInt32) -> Int32
  typealias CreateContext = @convention(c) () -> Int32
  typealias FreeContext = @convention(c) (UInt32) -> Int32
  typealias SetVMConfig = @convention(c) (UInt32, UInt8, UInt32) -> Int32
  typealias ToggleImplicitDevice = @convention(c) (UInt32) -> Int32
  typealias AddDisk =
    @convention(c) (UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool) -> Int32
  typealias AddVsock = @convention(c) (UInt32, UInt32) -> Int32
  typealias AddVsockPort = @convention(c) (UInt32, UInt32, UnsafePointer<CChar>?, Bool) -> Int32
  typealias AddNetUnixgram =
    @convention(c) (
      UInt32,
      UnsafePointer<CChar>?,
      Int32,
      UnsafeMutablePointer<UInt8>?,
      UInt32,
      UInt32
    ) -> Int32
  typealias AddConsole = @convention(c) (UInt32, Int32, Int32, Int32) -> Int32
  typealias SetKernel =
    @convention(c) (
      UInt32,
      UnsafePointer<CChar>?,
      UInt32,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?
    ) -> Int32
  typealias StartEnter = @convention(c) (UInt32) -> Int32

  private let handle: UnsafeMutableRawPointer
  let initLog: InitLog
  let createContext: CreateContext
  let freeContext: FreeContext
  let setVMConfig: SetVMConfig
  let disableImplicitVsock: ToggleImplicitDevice
  let addDisk: AddDisk
  let addVsock: AddVsock
  let addVsockPort: AddVsockPort
  let addNetUnixgram: AddNetUnixgram
  let disableImplicitConsole: ToggleImplicitDevice
  let addConsole: AddConsole
  let setKernel: SetKernel
  let startEnter: StartEnter

  init(path: String) throws {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      let detail = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
      throw KrunError(description: "cannot load libkrun at \(path): \(detail)")
    }
    self.handle = handle
    self.initLog = try Self.load(handle, "krun_init_log", as: InitLog.self)
    self.createContext = try Self.load(handle, "krun_create_ctx", as: CreateContext.self)
    self.freeContext = try Self.load(handle, "krun_free_ctx", as: FreeContext.self)
    self.setVMConfig = try Self.load(handle, "krun_set_vm_config", as: SetVMConfig.self)
    self.disableImplicitVsock = try Self.load(
      handle, "krun_disable_implicit_vsock", as: ToggleImplicitDevice.self)
    self.addDisk = try Self.load(handle, "krun_add_disk", as: AddDisk.self)
    self.addVsock = try Self.load(handle, "krun_add_vsock", as: AddVsock.self)
    self.addVsockPort = try Self.load(handle, "krun_add_vsock_port2", as: AddVsockPort.self)
    self.addNetUnixgram = try Self.load(
      handle, "krun_add_net_unixgram", as: AddNetUnixgram.self)
    self.disableImplicitConsole = try Self.load(
      handle, "krun_disable_implicit_console", as: ToggleImplicitDevice.self)
    self.addConsole = try Self.load(handle, "krun_add_virtio_console_default", as: AddConsole.self)
    self.setKernel = try Self.load(handle, "krun_set_kernel", as: SetKernel.self)
    self.startEnter = try Self.load(handle, "krun_start_enter", as: StartEnter.self)
  }

  deinit {
    dlclose(handle)
  }

  private static func load<T>(_ handle: UnsafeMutableRawPointer, _ symbol: String, as: T.Type)
    throws -> T
  {
    guard let pointer = dlsym(handle, symbol) else {
      let detail = dlerror().map { String(cString: $0) } ?? "missing symbol"
      throw KrunError(description: "libkrun does not export \(symbol): \(detail)")
    }
    return unsafeBitCast(pointer, to: T.self)
  }
}

private func checked(_ result: Int32, _ operation: String) throws {
  guard result >= 0 else {
    throw KrunError(description: "\(operation) failed with libkrun error \(result)")
  }
}

private func withCString<Result>(_ value: String, _ body: (UnsafePointer<CChar>) throws -> Result)
  rethrows -> Result
{
  try value.withCString(body)
}

private func run(config: KrunVMMConfig) throws -> Never {
  let krun = try KrunLibrary(path: config.libkrun)
  try checked(krun.initLog(-1, 3, 2, 0), "krun_init_log")

  let created = krun.createContext()
  guard created >= 0 else {
    throw KrunError(description: "krun_create_ctx failed with libkrun error \(created)")
  }
  let context = UInt32(created)
  defer { _ = krun.freeContext(context) }

  try checked(krun.setVMConfig(context, config.cpus, config.memoryMiB), "krun_set_vm_config")

  // Avoid libkrun's implicit TSI mode. Apple's stock Container kernel uses
  // ordinary virtio-vsock and already negotiates free-page reporting.
  try checked(krun.disableImplicitVsock(context), "krun_disable_implicit_vsock")
  try checked(krun.addVsock(context, 0), "krun_add_vsock(no TSI)")
  for mapping in config.vsockMappings {
    try withCString(mapping.path) { path in
      try checked(
        krun.addVsockPort(context, mapping.port, path, mapping.listen),
        "krun_add_vsock_port2(\(mapping.port))"
      )
    }
  }

  for (index, network) in config.networks.enumerated() {
    guard network.macAddress.count == 6 else {
      throw KrunError(description: "network \(index) MAC address must contain 6 bytes")
    }
    var mac = network.macAddress
    try withCString(network.socketPath) { path in
      try mac.withUnsafeMutableBufferPointer { bytes in
        try checked(
          krun.addNetUnixgram(
            context,
            path,
            -1,
            bytes.baseAddress,
            network.features,
            network.flags
          ),
          "krun_add_net_unixgram(net\(index))"
        )
      }
    }
  }

  try withCString("init") { id in
    try withCString(config.initDisk) { disk in
      try checked(krun.addDisk(context, id, disk, true), "krun_add_disk(init)")
    }
  }
  try withCString("root") { id in
    try withCString(config.rootDisk) { disk in
      try checked(krun.addDisk(context, id, disk, false), "krun_add_disk(root)")
    }
  }

  // Ensure Apple's console=hvc0 points at our boot log.
  try checked(krun.disableImplicitConsole(context), "krun_disable_implicit_console")
  let nullFD = open("/dev/null", O_RDONLY)
  guard nullFD >= 0 else { throw POSIXError(.EIO) }
  defer { close(nullFD) }
  let logFD = open(config.bootLog, O_WRONLY | O_CREAT | O_APPEND, 0o600)
  guard logFD >= 0 else { throw POSIXError(.EIO) }
  defer { close(logFD) }
  try checked(krun.addConsole(context, nullFD, logFD, logFD), "krun_add_virtio_console_default")

  try withCString(config.kernel) { kernel in
    try withCString(config.commandLine) { commandLine in
      // Apple Silicon Container kernels are raw arm64 Image-format kernels.
      try checked(krun.setKernel(context, kernel, 0, nil, commandLine), "krun_set_kernel")
    }
  }

  let result = krun.startEnter(context)
  throw KrunError(description: "krun_start_enter unexpectedly returned \(result)")
}

@main
private enum Main {
  static func main() {
    do {
      guard CommandLine.arguments.count == 2 else {
        throw KrunError(description: "usage: container-krun-vmm-helper CONFIG.json")
      }
      let config = try JSONDecoder().decode(
        KrunVMMConfig.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      )
      try run(config: config)
    } catch {
      FileHandle.standardError.write(Data("container-krun-vmm-helper: \(error)\n".utf8))
      exit(1)
    }
  }
}
