import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

public actor KrunPortPool {
  public struct Lease: Sendable, Hashable {
    public let port: UInt32
    public let path: String
  }

  private let name: String
  private let rotateReleased: Bool
  private var available: [Lease]

  public init(
    entries: [KrunSocketLayout.IOEntry],
    name: String = "I/O",
    rotateReleased: Bool = false
  ) {
    self.name = name
    self.rotateReleased = rotateReleased
    self.available = entries.map { Lease(port: $0.port, path: $0.path) }
  }

  public func take(_ count: Int) throws -> [Lease] {
    guard count <= available.count else {
      throw ContainerizationError(
        .internalError,
        message:
          "libkrun \(name) port pool exhausted (requested \(count), available \(available.count))"
      )
    }
    let leases = Array(available.prefix(count))
    available.removeFirst(count)
    return leases
  }

  public func put(_ leases: [Lease]) {
    available.append(contentsOf: leases)
    if !rotateReleased {
      available.sort { $0.port < $1.port }
    }
  }
}

public final class KrunProcessIO: @unchecked Sendable {
  public let stdinPort: UInt32?
  public let stdoutPort: UInt32?
  public let stderrPort: UInt32?

  private let pool: KrunPortPool
  private let leases: [KrunPortPool.Lease]
  private let hostHandles: [FileHandle?]
  private let listeners: [Socket?]
  private let accepts: [Task<FileHandle?, Error>]
  private var guestHandles = [FileHandle?](repeating: nil, count: 3)
  private var inputTask: Task<Void, Never>?
  private var outputTasks: [Task<Void, Never>] = []

  private init(
    pool: KrunPortPool,
    leases: [KrunPortPool.Lease],
    hostHandles: [FileHandle?],
    listeners: [Socket?],
    accepts: [Task<FileHandle?, Error>],
    ports: [UInt32?]
  ) {
    self.pool = pool
    self.leases = leases
    self.hostHandles = hostHandles
    self.listeners = listeners
    self.accepts = accepts
    self.stdinPort = ports[0]
    self.stdoutPort = ports[1]
    self.stderrPort = ports[2]
  }

  public static func prepare(
    hostHandles inputHandles: [FileHandle?],
    terminal: Bool,
    pool: KrunPortPool
  ) async throws -> KrunProcessIO {
    var hostHandles = [FileHandle?](repeating: nil, count: 3)
    for i in 0..<min(inputHandles.count, 3) {
      hostHandles[i] = inputHandles[i]
    }
    if terminal, hostHandles[2] != nil {
      throw ContainerizationError(
        .invalidArgument, message: "stderr cannot be separate when terminal=true")
    }

    let needed = hostHandles.compactMap { $0 }.count
    let leases = try await pool.take(needed)
    var leaseIndex = 0
    var ports = [UInt32?](repeating: nil, count: 3)
    var listeners = [Socket?](repeating: nil, count: 3)
    var accepts = [Task<FileHandle?, Error>]()

    do {
      for index in 0..<3 {
        guard hostHandles[index] != nil else {
          accepts.append(Task { nil })
          continue
        }
        let lease = leases[leaseIndex]
        leaseIndex += 1
        ports[index] = lease.port
        let socket = try Socket(
          type: UnixType(path: lease.path, perms: 0o600, unlinkExisting: true),
          closeOnDeinit: true
        )
        try socket.listen()
        listeners[index] = socket
        let stream = try socket.acceptStream()
        accepts.append(
          Task {
            var iterator = stream.makeAsyncIterator()
            guard let connection = try await iterator.next() else {
              throw ContainerizationError(
                .internalError,
                message: "stdio vsock mapping \(lease.port) closed before guest connected"
              )
            }
            let fd = dup(connection.fileDescriptor)
            guard fd >= 0 else {
              throw POSIXError(.EIO)
            }
            try? connection.close()
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
          }
        )
      }
    } catch {
      for task in accepts {
        task.cancel()
      }
      for listener in listeners.compactMap({ $0 }) {
        try? listener.close()
      }
      await pool.put(leases)
      throw error
    }

    return KrunProcessIO(
      pool: pool,
      leases: leases,
      hostHandles: hostHandles,
      listeners: listeners,
      accepts: accepts,
      ports: ports
    )
  }

  public func waitForGuestConnections() async throws {
    for index in 0..<3 {
      guestHandles[index] = try await accepts[index].value
      try? listeners[index]?.close()
    }
  }

  public func startRelays(agent: Vminitd, id: String, containerID: String) {
    if let host = hostHandles[0], let guest = guestHandles[0] {
      inputTask = Task {
        for await data in Self.stream(host) {
          do {
            try guest.write(contentsOf: data)
          } catch {
            break
          }
        }
        try? guest.close()
        try? await agent.closeProcessStdin(id: id, containerID: containerID)
      }
    }
    for index in 1...2 {
      guard let host = hostHandles[index], let guest = guestHandles[index] else { continue }
      outputTasks.append(
        Task {
          for await data in Self.stream(guest) {
            do {
              try host.write(contentsOf: data)
            } catch {
              break
            }
          }
          try? guest.close()
        }
      )
    }
  }

  public func waitForOutput() async {
    await Self.waitForOutputTasks(outputTasks, timeout: .seconds(3))
    inputTask?.cancel()
    for index in 1...2 {
      try? hostHandles[index]?.close()
    }
  }

  static func waitForOutputTasks(_ tasks: [Task<Void, Never>], timeout: Duration) async {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for task in tasks {
          await task.value
        }
        return true
      }
      group.addTask {
        // Caller cancellation also ends the grace period immediately.
        try? await Task.sleep(for: timeout)
        return false
      }
      if await group.next() == false {
        // The relays are unstructured tasks, not children of this group.
        // Cancel them before the group joins the child awaiting their values.
        for task in tasks {
          task.cancel()
        }
      }
      group.cancelAll()
    }
  }

  public func close() async {
    inputTask?.cancel()
    for task in outputTasks {
      task.cancel()
    }
    for handle in guestHandles.compactMap({ $0 }) {
      handle.readabilityHandler = nil
      try? handle.close()
    }
    for handle in hostHandles.compactMap({ $0 }) {
      handle.readabilityHandler = nil
      try? handle.close()
    }
    for listener in listeners.compactMap({ $0 }) {
      try? listener.close()
    }
    for lease in leases {
      try? FileManager.default.removeItem(atPath: lease.path)
    }
    await pool.put(leases)
  }

  private static func stream(_ handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream { continuation in
      handle.readabilityHandler = { readable in
        let data = readable.availableData
        if data.isEmpty {
          readable.readabilityHandler = nil
          continuation.finish()
        } else {
          continuation.yield(data)
        }
      }
      continuation.onTermination = { _ in
        handle.readabilityHandler = nil
      }
    }
  }
}
