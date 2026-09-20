import Dispatch
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

private enum HelperLifecycleTrace {
  static func mark(
    startedAt: ContinuousClock.Instant,
    event: String,
    metadata: [String: String] = [:]
  ) {
    let components = startedAt.duration(to: ContinuousClock.now).components
    let elapsedMilliseconds =
      components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    var line = "helper lifecycle [event=\(event)] [elapsed_ms=\(elapsedMilliseconds)]"
    for key in metadata.keys.sorted() {
      if let value = metadata[key] {
        line += " [\(key)=\(value)]"
      }
    }
    line += "\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

private final class KrunLibrary: @unchecked Sendable {
  typealias InitLog = @convention(c) (Int32, UInt32, UInt32, UInt32) -> Int32
  typealias CreateContext = @convention(c) (UInt32) -> Int32
  typealias FreeContext = @convention(c) (UInt32) -> Int32
  typealias SetVMConfig = @convention(c) (UInt32, UInt8, UInt32) -> Int32
  typealias ToggleImplicitDevice = @convention(c) (UInt32) -> Int32
  typealias AddDisk =
    @convention(c) (UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool) -> Int32
  typealias AddDisk3 =
    @convention(c) (
      UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, Bool, Bool, UInt32
    ) -> Int32
  typealias AddVirtioFS4 =
    @convention(c) (
      UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt64, Bool, UInt32
    ) -> Int32
  typealias AddVsock = @convention(c) (UInt32, UInt32) -> Int32
  typealias AddVsockPort = @convention(c) (UInt32, UInt32, UnsafePointer<CChar>?, Bool) -> Int32
  typealias AddNetVMNetShared =
    @convention(c) (
      UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
      UnsafeMutablePointer<UInt8>?, UInt32, UInt32
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
  typealias RequestVMMStop = @convention(c) (UInt32) -> Int32
  typealias StartEnter = @convention(c) (UInt32) -> Int32

  private let handle: UnsafeMutableRawPointer
  let initLog: InitLog
  let createContext: CreateContext
  let freeContext: FreeContext
  let setVMConfig: SetVMConfig
  let disableImplicitVsock: ToggleImplicitDevice
  let addDisk: AddDisk
  let addDisk3: AddDisk3?
  let addVirtioFS4: AddVirtioFS4?
  let addVsock: AddVsock
  let addVsockPort: AddVsockPort
  let addNetVMNetShared: AddNetVMNetShared
  let disableImplicitConsole: ToggleImplicitDevice
  let addConsole: AddConsole
  let setKernel: SetKernel
  let requestVMMStop: RequestVMMStop
  let startEnter: StartEnter

  init(path: String) throws {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      let detail = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
      throw KrunError(description: "cannot load libkrun at \(path): \(detail)")
    }
    self.handle = handle
    self.initLog = try Self.load(handle, "krun_init_log", as: InitLog.self)
    self.createContext = try Self.load(handle, "krun_create_ctx2", as: CreateContext.self)
    self.freeContext = try Self.load(handle, "krun_free_ctx", as: FreeContext.self)
    self.setVMConfig = try Self.load(handle, "krun_set_vm_config", as: SetVMConfig.self)
    self.disableImplicitVsock = try Self.load(
      handle, "krun_disable_implicit_vsock", as: ToggleImplicitDevice.self)
    self.addDisk = try Self.load(handle, "krun_add_disk", as: AddDisk.self)
    self.addDisk3 = Self.loadOptional(handle, "krun_add_disk3", as: AddDisk3.self)
    self.addVirtioFS4 = Self.loadOptional(handle, "krun_add_virtiofs4", as: AddVirtioFS4.self)
    self.addVsock = try Self.load(handle, "krun_add_vsock", as: AddVsock.self)
    self.addVsockPort = try Self.load(handle, "krun_add_vsock_port2", as: AddVsockPort.self)
    self.addNetVMNetShared = try Self.load(
      handle, "krun_add_net_vmnet_shared", as: AddNetVMNetShared.self)
    self.disableImplicitConsole = try Self.load(
      handle, "krun_disable_implicit_console", as: ToggleImplicitDevice.self)
    self.addConsole = try Self.load(handle, "krun_add_virtio_console_default", as: AddConsole.self)
    self.setKernel = try Self.load(handle, "krun_set_kernel", as: SetKernel.self)
    self.requestVMMStop = try Self.load(handle, "krun_request_vmm_stop", as: RequestVMMStop.self)
    self.startEnter = try Self.load(handle, "krun_start_enter", as: StartEnter.self)
  }

  deinit {
    dlclose(handle)
  }

  private static func loadOptional<T>(
    _ handle: UnsafeMutableRawPointer, _ symbol: String, as: T.Type
  ) -> T? {
    guard let pointer = dlsym(handle, symbol) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
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

private func run(config: KrunVMMConfig, startedAt: ContinuousClock.Instant) throws -> Never {
  let target = try NativeVMNetPrivileges.validate(config: config)
  let krun = try KrunLibrary(path: config.libkrun)
  HelperLifecycleTrace.mark(
    startedAt: startedAt, event: "libkrun loaded",
    metadata: ["path": config.libkrun]
  )
  try checked(krun.initLog(-1, 3, 2, 1), "krun_init_log(no environment)")

  // Context creation must not search for libkrunfw while this process is root.
  // This runtime always supplies Apple's explicit kernel below.
  let created = krun.createContext(1) // KRUN_CTX_NO_DEFAULT_FIRMWARE
  guard created >= 0 else {
    throw KrunError(description: "krun_create_ctx2 failed with libkrun error \(created)")
  }
  let context = UInt32(created)
  defer { _ = krun.freeContext(context) }
  HelperLifecycleTrace.mark(startedAt: startedAt, event: "context created", metadata: ["default_firmware": "disabled"])

  // Only native interface creation is privileged. No VM files or guest CPU
  // execution are touched until the irreversible UID/GID drop has completed.
  for (index, network) in config.networks.enumerated() {
    var mac = network.macAddress
    try network.ipv4Gateway.withCString { gateway in
      try network.ipv4Mask.withCString { mask in
        try mac.withUnsafeMutableBufferPointer { bytes in
          try checked(
            krun.addNetVMNetShared(context, gateway, mask, bytes.baseAddress, network.features, network.flags),
            "krun_add_net_vmnet_shared(net\(index))"
          )
        }
      }
    }
    HelperLifecycleTrace.mark(
      startedAt: startedAt, event: "native vmnet interface ready",
      metadata: [
        "backend": "libkrun-vmnet-shared", "network_index": "\(index)",
        "api": "krun_add_net_vmnet_shared", "vmnet_api": "vmnet_start_interface",
        "guest_dhcp": "false", "isolated": "true",
        "gateway": network.ipv4Gateway, "netmask": network.ipv4Mask,
        "features": "\(network.features)", "flags": "\(network.flags)",
      ]
    )
  }
  if let target {
    try NativeVMNetPrivileges.drop(to: target)
    HelperLifecycleTrace.mark(
      startedAt: startedAt, event: "helper privileges dropped",
      metadata: [
        "uid": "\(getuid())", "euid": "\(geteuid())",
        "gid": "\(getgid())", "egid": "\(getegid())",
        "root_regain_blocked": "true", "pid": "\(getpid())",
      ]
    )
  }

  try checked(krun.setVMConfig(context, config.cpus, config.memoryMiB), "krun_set_vm_config")
  HelperLifecycleTrace.mark(startedAt: startedAt, event: "basic VM configuration complete")

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
  HelperLifecycleTrace.mark(
    startedAt: startedAt,
    event: "vsock mappings registered",
    metadata: ["mapping_count": "\(config.vsockMappings.count)"]
  )

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

  if !config.disks.isEmpty {
    guard let addDisk3 = krun.addDisk3 else {
      throw KrunError(description: "libkrun does not export krun_add_disk3 required for volumes")
    }
    for disk in config.disks {
      try withCString(disk.blockID) { id in
        try withCString(disk.path) { path in
          try checked(
            addDisk3(
              context,
              id,
              path,
              0, // KRUN_DISK_FORMAT_RAW
              disk.readOnly,
              disk.directIO,
              disk.syncMode.rawValue
            ),
            "krun_add_disk3(\(disk.blockID))"
          )
        }
      }
    }
  }

  if !config.virtioFS.isEmpty {
    guard let addVirtioFS4 = krun.addVirtioFS4 else {
      throw KrunError(
        description: "libkrun does not export krun_add_virtiofs4 required for host directory mounts"
      )
    }
    for share in config.virtioFS {
      try withCString(share.tag) { tag in
        try withCString(share.path) { path in
          try checked(
            addVirtioFS4(
              context,
              tag,
              path,
              share.shmSize,
              share.readOnly,
              share.semantics.rawValue
            ),
            "krun_add_virtiofs4(\(share.tag))"
          )
        }
      }
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
  HelperLifecycleTrace.mark(startedAt: startedAt, event: "device configuration complete")

  // The runtime stops the per-VM helper with SIGTERM. Convert that process
  // signal into a libkrun VMM stop event. The VMM event loop runs exit
  // observers (including native vmnet teardown) before terminating with _exit().
  signal(SIGTERM, SIG_IGN)
  let terminationSource = DispatchSource.makeSignalSource(
    signal: SIGTERM,
    queue: DispatchQueue(label: "com.github.robertderose.container-runtime-krun.shutdown")
  )
  terminationSource.setEventHandler {
    let result = krun.requestVMMStop(context)
    HelperLifecycleTrace.mark(
      startedAt: startedAt,
      event: "VMM stop requested",
      metadata: ["result": "\(result)"]
    )
  }
  terminationSource.resume()
  defer {
    terminationSource.cancel()
    signal(SIGTERM, SIG_DFL)
  }

  HelperLifecycleTrace.mark(startedAt: startedAt, event: "krun_start_enter start")
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
      let startedAt = ContinuousClock.now
      HelperLifecycleTrace.mark(
        startedAt: startedAt, event: "helper start",
        metadata: ["pid": "\(getpid())", "uid": "\(getuid())", "euid": "\(geteuid())"]
      )
      let config = try JSONDecoder().decode(
        KrunVMMConfig.self,
        from: NativeVMNetPrivileges.loadConfiguration(path: CommandLine.arguments[1])
      )
      try run(config: config, startedAt: startedAt)
    } catch {
      FileHandle.standardError.write(Data("container-krun-vmm-helper: \(error)\n".utf8))
      exit(1)
    }
  }
}
