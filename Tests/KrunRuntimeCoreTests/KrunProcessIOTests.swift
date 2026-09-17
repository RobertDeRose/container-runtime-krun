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
