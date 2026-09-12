import ContainerResource
import KrunRuntimeCore
import Testing

@Test func socketLayoutUsesShortUniquePaths() {
  let layout = KrunSocketLayout(id: "example-container")
  let guestToHostEntries = layout.ioEntries + layout.copyEntries

  #expect(layout.controlPath.utf8.count < 100)
  // Three stdio streams for each of the 32 process slots guaranteed by v0.1.
  #expect(layout.ioEntries.count == 96)
  #expect(!layout.copyEntries.isEmpty)
  #expect(Set(guestToHostEntries.map(\.port)).count == guestToHostEntries.count)
  #expect(Set(guestToHostEntries.map(\.path)).count == guestToHostEntries.count)
  #expect(guestToHostEntries.allSatisfy { $0.path.utf8.count < 100 })
  #expect(layout.mappings.count == guestToHostEntries.count + 1)
  #expect(layout.mappings.first?.listen == true)
  #expect(layout.mappings.dropFirst().allSatisfy { !$0.listen })
}
