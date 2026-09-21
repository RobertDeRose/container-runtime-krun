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
