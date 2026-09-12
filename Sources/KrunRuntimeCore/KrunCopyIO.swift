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

    let agent = try await controller.dialAgent()
    do {
      let guestPath = try await resolveCopyInGuestPath(
        source: source,
        destination: destination,
        sourceIsDirectory: isArchive,
        rootPath: controller.rootPath,
        agent: agent
      )
      let channel = try await KrunCopyChannel.prepare(pool: pool)
      try await run(channel: channel) { group in
        group.addTask {
          try await agent.copy(
            direction: .copyIn,
            guestPath: guestPath,
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
      try await agent.close()
    } catch {
      try? await agent.close()
      throw error
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

    let guestPath = URL(filePath: controller.rootPath).appending(path: source.path)
    let agent = try await controller.dialAgent()
    let channel: KrunCopyChannel
    do {
      channel = try await KrunCopyChannel.prepare(pool: pool)
    } catch {
      try? await agent.close()
      throw error
    }

    let (metadataStream, metadataContinuation) = AsyncStream.makeStream(
      of: Vminitd.CopyMetadata.self
    )
    do {
      try await run(channel: channel) { group in
        group.addTask {
          defer { metadataContinuation.finish() }
          try await agent.copy(
            direction: .copyOut,
            guestPath: guestPath,
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
          let connection = try await channel.accept()
          try await KrunCopyTransfer.receive(
            destination: destination,
            isArchive: metadata.isArchive,
            from: connection
          )
        }
      }
      try await agent.close()
    } catch {
      try? await agent.close()
      throw error
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
    rootPath: String,
    agent: Vminitd
  ) async throws -> URL {
    let guestDestination = URL(filePath: rootPath).appending(path: destination.path)

    let stat: ContainerizationOS.Stat?
    do {
      stat = try await agent.stat(path: guestDestination)
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
      defer { try? connection.close() }

      if isArchive {
        let writer = try ArchiveWriter(configuration: .init(format: .pax, filter: .gzip))
        try writer.open(fileDescriptor: connection.fileDescriptor)
        try writer.archiveDirectory(source)
        try writer.finishEncoding()
        return
      }

      let sourceFD = open(source.path, O_RDONLY)
      guard sourceFD >= 0 else {
        throw posixError("copyIn: failed to open '\(source.path)'")
      }
      defer { close(sourceFD) }

      try copyBytes(from: sourceFD, to: connection.fileDescriptor, chunkSize: chunkSize, operation: "copyIn")
    }
  }

  static func receive(
    destination: URL,
    isArchive: Bool,
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
        operation: "copyOut"
      )
    }
  }

  private static func copyBytes(
    from sourceFD: Int32,
    to destinationFD: Int32,
    chunkSize: Int,
    operation: String
  ) throws {
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let count = read(sourceFD, &buffer, buffer.count)
      if count == 0 { return }
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
