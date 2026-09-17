import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOS
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// One predeclared guest-to-host vsock mapping used for a copy operation.
///
/// libkrun cannot add vsock mappings after the VM starts, so copy traffic leases
/// a mapping that was configured before boot. The listener itself is created only
/// while a copy is active.
enum KrunCopyOperations {
  static func copyIn(
    controller: KrunVMController,
    pool: KrunPortPool,
    source: URL,
    destination: URL,
    mode: UInt32,
    createParents: Bool
  ) async throws {
    var sourceIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
      throw ContainerizationError(.notFound, message: "copyIn: source not found '\(source.path)'")
    }
    let isArchive = sourceIsDirectory.boolValue

    let agent = controller.agent
    let resolvedDestination = KrunContainerPath.resolve(
      controller: controller,
      path: destination
    )
    if resolvedDestination.readOnly {
      throw ContainerizationError(
        .invalidArgument,
        message: "copyIn: destination is on a read-only volume mount: \(destination.path)"
      )
    }
    let guestPath = try await resolveCopyInGuestPath(
      source: source,
      destination: destination,
      sourceIsDirectory: isArchive,
      guestDestination: resolvedDestination,
      agent: agent
    )
    let channel = try await KrunCopyChannel.prepare(pool: pool)
    try await run(channel: channel) { group in
      group.addTask {
        try await agent.copy(
          direction: .copyIn,
          root: guestPath.root,
          path: guestPath.path,
          vsockPort: channel.port,
          mode: mode,
          createParents: createParents,
          isArchive: isArchive
        )
      }
      group.addTask {
        let connection = try await channel.accept()
        try await KrunCopyTransfer.send(
          source: source,
          isArchive: isArchive,
          to: connection
        )
      }
    }
  }

  static func copyOut(
    controller: KrunVMController,
    pool: KrunPortPool,
    source: URL,
    destination: URL,
    createParents: Bool
  ) async throws {
    if createParents {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }

    let guestPath = KrunContainerPath.resolve(controller: controller, path: source)
    let agent = controller.agent

    // libkrun forwards all guest-to-host streams on one muxer thread. Learn the
    // transfer shape first so the data socket can be drained as soon as it connects,
    // without waiting for streamed copy metadata on the same vsock device.
    let sourceStat = try await agent.stat(root: guestPath.root, path: guestPath.path)
    let preflightIsArchive = (sourceStat.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    guard preflightIsArchive || sourceStat.size >= 0 else {
      throw ContainerizationError(
        .internalError,
        message: "copyOut: source has invalid size: \(sourceStat.size)"
      )
    }
    let preflightTotalSize = preflightIsArchive ? 0 : UInt64(sourceStat.size)
    let channel = try await KrunCopyChannel.prepare(pool: pool)
    let (metadataStream, metadataContinuation) = AsyncStream.makeStream(
      of: Vminitd.CopyMetadata.self
    )
    try await run(channel: channel) { group in
      group.addTask {
        defer { metadataContinuation.finish() }
        try await agent.copy(
          direction: .copyOut,
          root: guestPath.root,
          path: guestPath.path,
          vsockPort: channel.port,
          onMetadata: { metadata in
            metadataContinuation.yield(metadata)
            metadataContinuation.finish()
          }
        )
      }
      group.addTask {
        guard let metadata = await metadataStream.first(where: { _ in true }) else {
          throw ContainerizationError(.internalError, message: "copyOut: no metadata received")
        }
        try validateCopyOutMetadata(
          isArchive: metadata.isArchive,
          totalSize: metadata.totalSize,
          expectedArchive: preflightIsArchive,
          expectedSize: preflightTotalSize
        )
      }
      group.addTask {
        let connection = try await channel.accept()
        try await KrunCopyTransfer.receive(
          destination: destination,
          isArchive: preflightIsArchive,
          totalSize: preflightTotalSize,
          from: connection
        )
      }
    }
  }

  static func validateCopyOutMetadata(
    isArchive: Bool,
    totalSize: UInt64,
    expectedArchive: Bool,
    expectedSize: UInt64
  ) throws {
    guard isArchive == expectedArchive else {
      throw ContainerizationError(
        .internalError,
        message: "copyOut: source type changed while preparing transfer"
      )
    }
    guard isArchive || totalSize == expectedSize else {
      throw ContainerizationError(
        .internalError,
        message: "copyOut: source size changed while preparing transfer"
      )
    }
  }

  private static func run(
    channel: KrunCopyChannel,
    addTasks: (inout ThrowingTaskGroup<Void, any Error>) -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      addTasks(&group)
      do {
        while try await group.next() != nil {}
      } catch {
        group.cancelAll()
        await channel.close()
        throw error
      }
    }
    await channel.close()
  }

  private static func resolveCopyInGuestPath(
    source: URL,
    destination: URL,
    sourceIsDirectory: Bool,
    guestDestination: KrunResolvedContainerPath,
    agent: Vminitd
  ) async throws -> KrunResolvedContainerPath {
    let stat: ContainerizationOS.Stat?
    do {
      stat = try await agent.stat(root: guestDestination.root, path: guestDestination.path)
    } catch let error as ContainerizationError where error.code == .notFound {
      stat = nil
    }

    guard let stat else {
      if destination.hasDirectoryPath && !sourceIsDirectory {
        throw ContainerizationError(
          .invalidArgument,
          message: "destination directory does not exist: \(destination.path)"
        )
      }
      return guestDestination
    }

    let destinationIsDirectory = (stat.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    guard destinationIsDirectory else {
      if sourceIsDirectory {
        throw ContainerizationError(
          .invalidArgument,
          message: "cannot copy directory over existing file: \(destination.path)"
        )
      }
      return guestDestination
    }

    return guestDestination.appendingPathComponent(source.lastPathComponent)
  }
}

actor KrunCopyChannel {
  nonisolated let port: UInt32

  private let pool: KrunPortPool
  private let lease: KrunPortPool.Lease
  private let listener: Socket
  private let acceptTask: Task<FileHandle, Error>
  private var acceptedHandle: FileHandle?
  private var closed = false

  static func prepare(pool: KrunPortPool) async throws -> KrunCopyChannel {
    let leases = try await pool.take(1)
    guard let lease = leases.first else {
      throw ContainerizationError(.internalError, message: "copy port pool returned no lease")
    }

    do {
      let listener = try Socket(
        type: UnixType(path: lease.path, perms: 0o600, unlinkExisting: true),
        closeOnDeinit: true
      )
      try listener.listen()
      let stream = try listener.acceptStream()
      let acceptTask = Task<FileHandle, Error> {
        var iterator = stream.makeAsyncIterator()
        guard let connection = try await iterator.next() else {
          throw ContainerizationError(
            .internalError,
            message: "copy vsock mapping \(lease.port) closed before guest connected"
          )
        }
        if Task.isCancelled {
          try? connection.close()
          throw CancellationError()
        }
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
          throw POSIXError(.EIO)
        }
        try? connection.close()
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      }
      return KrunCopyChannel(
        pool: pool,
        lease: lease,
        listener: listener,
        acceptTask: acceptTask
      )
    } catch {
      try? FileManager.default.removeItem(atPath: lease.path)
      await pool.put(leases)
      throw error
    }
  }

  private init(
    pool: KrunPortPool,
    lease: KrunPortPool.Lease,
    listener: Socket,
    acceptTask: Task<FileHandle, Error>
  ) {
    self.port = lease.port
    self.pool = pool
    self.lease = lease
    self.listener = listener
    self.acceptTask = acceptTask
  }

  func accept() async throws -> FileHandle {
    let handle = try await acceptTask.value
    try? listener.close()
    guard !closed else {
      try? handle.close()
      throw CancellationError()
    }
    acceptedHandle = handle
    return handle
  }

  func close() async {
    guard !closed else { return }
    closed = true
    acceptTask.cancel()
    try? listener.close()
    try? acceptedHandle?.close()
    try? FileManager.default.removeItem(atPath: lease.path)
    await pool.put([lease])
  }
}

enum KrunCopyTransfer {
  static let defaultChunkSize = 1024 * 1024

  static func send(
    source: URL,
    isArchive: Bool,
    to connection: FileHandle,
    chunkSize: Int = defaultChunkSize
  ) async throws {
    try await blocking {
      if isArchive {
        let writer = try ArchiveWriter(configuration: .init(format: .pax, filter: .gzip))
        try writer.open(fileDescriptor: connection.fileDescriptor)
        try writer.archiveDirectory(source)
        try writer.finishEncoding()
      } else {
        let sourceFD = open(source.path, O_RDONLY)
        guard sourceFD >= 0 else {
          throw posixError("copyIn: failed to open '\(source.path)'")
        }
        defer { close(sourceFD) }

        try copyBytes(
          from: sourceFD,
          to: connection.fileDescriptor,
          chunkSize: chunkSize,
          operation: "copyIn"
        )
      }

      // vminitd frames copy-in with EOF. Keep the read half alive until the
      // copy RPC completes so libkrun sees an orderly half-close instead of a
      // host-side HANG_UP while the guest still owns the stream.
      try finishWriting(connection.fileDescriptor)
    }
  }

  static func finishWriting(_ fileDescriptor: Int32) throws {
    guard shutdown(fileDescriptor, SHUT_WR) == 0 else {
      throw posixError("copyIn: failed to finish data stream")
    }
  }

  static func receive(
    destination: URL,
    isArchive: Bool,
    totalSize: UInt64,
    from connection: FileHandle,
    chunkSize: Int = defaultChunkSize
  ) async throws {
    try await blocking {
      defer { try? connection.close() }

      if isArchive {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archiveFD = dup(connection.fileDescriptor)
        guard archiveFD >= 0 else {
          throw POSIXError(.EIO)
        }
        let archiveHandle = FileHandle(fileDescriptor: archiveFD, closeOnDealloc: true)
        let reader = try ArchiveReader(format: .pax, filter: .gzip, fileHandle: archiveHandle)
        _ = try reader.extractContents(to: destination)
        return
      }

      let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
      guard destinationFD >= 0 else {
        throw posixError("copyOut: failed to open '\(destination.path)'")
      }
      defer { close(destinationFD) }

      try copyBytes(
        from: connection.fileDescriptor,
        to: destinationFD,
        chunkSize: chunkSize,
        operation: "copyOut",
        byteCount: totalSize
      )
    }
  }

  static func copyBytes(
    from sourceFD: Int32,
    to destinationFD: Int32,
    chunkSize: Int,
    operation: String,
    byteCount: UInt64? = nil
  ) throws {
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var remaining = byteCount
    while remaining.map({ $0 > 0 }) ?? true {
      let readSize = remaining.map { Int(min(UInt64(buffer.count), $0)) } ?? buffer.count
      let count = read(sourceFD, &buffer, readSize)
      if count == 0 {
        if let remaining {
          throw ContainerizationError(
            .internalError,
            message: "\(operation): unexpected EOF with \(remaining) bytes remaining"
          )
        }
        return
      }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw posixError("\(operation): read failed")
      }

      var written = 0
      while written < count {
        let result = buffer.withUnsafeBytes { pointer in
          write(destinationFD, pointer.baseAddress!.advanced(by: written), count - written)
        }
        guard result >= 0 else {
          if errno == EINTR { continue }
          throw posixError("\(operation): write failed")
        }
        guard result > 0 else {
          throw ContainerizationError(.internalError, message: "\(operation): zero-byte write")
        }
        written += result
      }
      if let bytesRemaining = remaining {
        remaining = bytesRemaining - UInt64(count)
      }
    }
  }

  private static func blocking(_ work: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          try work()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func posixError(_ prefix: String) -> ContainerizationError {
    ContainerizationError(
      .internalError,
      message: "\(prefix): \(String(cString: strerror(errno)))"
    )
  }
}
