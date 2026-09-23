import ContainerRuntimeClient
import Foundation
import Testing

@Test func runtimeDialBehavioralProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let id = environment["KRUN_RUNTIME_DIAL_CONTAINER_ID"] else {
    return
  }
  let runtime = environment["KRUN_RUNTIME_DIAL_RUNTIME"] ?? "container-runtime-krun"
  let port = try #require(UInt32(environment["KRUN_RUNTIME_DIAL_PORT"] ?? ""))
  let unusedPort = try #require(UInt32(environment["KRUN_RUNTIME_DIAL_UNUSED_PORT"] ?? ""))
  let client = try await RuntimeClient.create(id: id, runtime: runtime)

  try await exchange(client: client, port: port, request: "host-one\n", response: "guest-one\n")
  try await exchange(client: client, port: port, request: "host-two\n", response: "guest-two\n")

  var rejected = false
  do {
    let handle = try await client.dial(unusedPort)
    try? handle.close()
  } catch {
    rejected = true
    print("expected failed dial: \(error)")
  }
  #expect(rejected)

  try await exchange(client: client, port: port, request: "host-three\n", response: "guest-three\n")
}

@Test func runtimeDialBenchmarkProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard
    let idA = environment["KRUN_RUNTIME_DIAL_BENCHMARK_CONTAINER_ID_A"],
    let runtimeA = environment["KRUN_RUNTIME_DIAL_BENCHMARK_RUNTIME_A"],
    let idB = environment["KRUN_RUNTIME_DIAL_BENCHMARK_CONTAINER_ID_B"],
    let runtimeB = environment["KRUN_RUNTIME_DIAL_BENCHMARK_RUNTIME_B"],
    let samplesPath = environment["KRUN_RUNTIME_DIAL_BENCHMARK_SAMPLES"]
  else {
    return
  }
  let port = try #require(UInt32(environment["KRUN_RUNTIME_DIAL_BENCHMARK_PORT"] ?? ""))
  let iterations = try #require(Int(environment["KRUN_RUNTIME_DIAL_BENCHMARK_ITERATIONS"] ?? ""))
  #expect(iterations > 0)

  let endpoints = [
    (runtimeA, try await RuntimeClient.create(id: idA, runtime: runtimeA)),
    (runtimeB, try await RuntimeClient.create(id: idB, runtime: runtimeB)),
  ]
  var payload = Data(repeating: 0x78, count: 64 * 1024)
  payload.append(0x0a)
  let clock = ContinuousClock()

  for iteration in 1...iterations {
    let order = iteration.isMultiple(of: 2) ? Array(endpoints.reversed()) : endpoints
    for (runtime, client) in order {
      let dialStart = clock.now
      let handle = try await client.dial(port)
      let dialDuration = dialStart.duration(to: clock.now)

      let transferStart = clock.now
      try handle.write(contentsOf: payload)
      let received = handle.readDataToEndOfFile()
      let transferDuration = transferStart.duration(to: clock.now)
      try handle.close()
      #expect(received == payload)

      try appendBenchmarkSample(
        path: samplesPath,
        runtime: runtime,
        metric: "vsock_dial_connect",
        iteration: iteration,
        duration: dialDuration
      )
      try appendBenchmarkSample(
        path: samplesPath,
        runtime: runtime,
        metric: "vsock_dial_roundtrip_64k",
        iteration: iteration,
        duration: transferDuration
      )
    }
  }
}

private func exchange(
  client: RuntimeClient,
  port: UInt32,
  request: String,
  response: String
) async throws {
  let handle = try await client.dial(port)
  defer { try? handle.close() }
  try handle.write(contentsOf: Data(request.utf8))
  let received = handle.readDataToEndOfFile()
  #expect(String(data: received, encoding: .utf8) == response)
}

private func appendBenchmarkSample(
  path: String,
  runtime: String,
  metric: String,
  iteration: Int,
  duration: Duration
) throws {
  let components = duration.components
  let milliseconds = Double(components.seconds) * 1_000.0 + Double(components.attoseconds) / 1_000_000_000_000_000.0
  let formatted = String(format: "%.3f", milliseconds)
  let row = Data("\(runtime)\t\(metric)\t\(iteration)\t\(formatted)\t0\n".utf8)
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: row)
}
