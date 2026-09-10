import ContainerResource
import KrunRuntimeCore
import Testing

@Test func socketLayoutUsesShortUniquePaths() {
  let layout = KrunSocketLayout(id: "example-container")
  #expect(layout.controlPath.utf8.count < 100)
  #expect(layout.ioEntries.count == 96)
  #expect(Set(layout.ioEntries.map(\.port)).count == layout.ioEntries.count)
  #expect(Set(layout.ioEntries.map(\.path)).count == layout.ioEntries.count)
  #expect(layout.mappings.first?.listen == true)
  #expect(layout.mappings.dropFirst().allSatisfy { !$0.listen })
}
