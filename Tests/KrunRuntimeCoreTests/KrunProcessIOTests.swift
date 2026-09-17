import Foundation
import Testing

@testable import KrunRuntimeCore

@Test func outputDrainPreservesAllCompletedOutput() async {
  let tasks = (0..<2).map { _ in
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.yield(Data("first".utf8))
    continuation.yield(Data("second".utf8))
    continuation.finish()
    return Task {
      var output = Data()
      for await data in stream {
        output.append(data)
      }
      #expect(output == Data("firstsecond".utf8))
    }
  }
  let drain = Task {
    await KrunProcessIO.waitForOutputTasks(tasks, timeout: .seconds(30))
  }
  let watchdog = outputDrainWatchdog(tasks + [drain])
  await drain.value
  watchdog.cancel()
  await watchdog.value
  #expect(tasks.allSatisfy { !$0.isCancelled })
}

@Test func outputDrainTimeoutCancelsStreamsWithoutEOF() async {
  let streams = (0..<2).map { _ in AsyncStream<Data>.makeStream() }
  let tasks = streams.map { entry in
    Task {
      for await _ in entry.stream {}
    }
  }
  let watchdog = outputDrainWatchdog(tasks)
  await KrunProcessIO.waitForOutputTasks(tasks, timeout: .milliseconds(20))
  watchdog.cancel()
  await watchdog.value
  #expect(tasks.allSatisfy { $0.isCancelled })
  for entry in streams { entry.continuation.finish() }
}

@Test func outputDrainCallerCancellationCancelsStreamsWithoutEOF() async {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let output = Task {
    for await _ in stream {}
  }
  let drain = Task {
    await KrunProcessIO.waitForOutputTasks([output], timeout: .seconds(30))
  }
  let watchdog = outputDrainWatchdog([output])
  drain.cancel()
  await drain.value
  watchdog.cancel()
  await watchdog.value
  #expect(output.isCancelled)
  continuation.finish()
}

@Test func outputDrainWithoutStreamsDoesNotWaitForTimeout() async {
  let drain = Task {
    await KrunProcessIO.waitForOutputTasks([], timeout: .seconds(30))
  }
  let watchdog = outputDrainWatchdog([drain])
  await drain.value
  watchdog.cancel()
  await watchdog.value
  #expect(!drain.isCancelled)
}

private func outputDrainWatchdog(_ tasks: [Task<Void, Never>]) -> Task<Void, Never> {
  Task {
    do {
      try await Task.sleep(for: .seconds(5))
    } catch {
      return
    }
    // Fail and rescue a broken drain instead of hanging the entire test suite.
    Issue.record("output drain did not finish before the test watchdog")
    for task in tasks { task.cancel() }
  }
}

@Test func detachedInitLoggingReservesOutputStreams() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let logPath = directory.appendingPathComponent("stdio.log")
  #expect(FileManager.default.createFile(atPath: logPath.path, contents: nil))
  let processLog = try KrunProcessLog(path: logPath)
  let entries = (0..<3).map { index in
    KrunSocketLayout.IOEntry(
      port: UInt32(100 + index),
      path: directory.appendingPathComponent("stdio-\(index).sock").path
    )
  }
  let pool = KrunPortPool(entries: entries)

  let io = try await KrunProcessIO.prepare(
    hostHandles: [nil, nil, nil],
    terminal: false,
    pool: pool,
    processLog: processLog
  )
  #expect(io.stdinPort == nil)
  #expect(io.stdoutPort == 100)
  #expect(io.stderrPort == 101)
  await io.close()
}

@Test func terminalInitLoggingUsesMergedOutputStream() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let logPath = directory.appendingPathComponent("stdio.log")
  #expect(FileManager.default.createFile(atPath: logPath.path, contents: nil))
  let processLog = try KrunProcessLog(path: logPath)
  let entries = (0..<2).map { index in
    KrunSocketLayout.IOEntry(
      port: UInt32(200 + index),
      path: directory.appendingPathComponent("terminal-\(index).sock").path
    )
  }
  let pool = KrunPortPool(entries: entries)

  let io = try await KrunProcessIO.prepare(
    hostHandles: [nil, nil, nil],
    terminal: true,
    pool: pool,
    processLog: processLog
  )
  #expect(io.stdinPort == nil)
  #expect(io.stdoutPort == 200)
  #expect(io.stderrPort == nil)
  await io.close()
}

@Test func processLogSerializesPersistentOutput() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let logPath = directory.appendingPathComponent("stdio.log")
  #expect(FileManager.default.createFile(atPath: logPath.path, contents: nil))
  let processLog = try KrunProcessLog(path: logPath)
  await processLog.write(Data("stdout\n".utf8))
  await processLog.write(Data("stderr\n".utf8))
  await processLog.close()

  #expect(try String(contentsOf: logPath, encoding: .utf8) == "stdout\nstderr\n")
}
