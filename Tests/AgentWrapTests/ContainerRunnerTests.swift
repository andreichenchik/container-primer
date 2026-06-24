import Testing

@testable import AgentWrap

struct ContainerRunnerTests {
  @Test func explicitCommandPassesThrough() {
    #expect(
      ContainerRunner.resolvedCommand(interactive: false, command: ["echo", "hi"]) == [
        "echo", "hi",
      ])
    #expect(
      ContainerRunner.resolvedCommand(interactive: true, command: ["/bin/bash"]) == ["/bin/bash"])
  }

  @Test func interactiveWithoutCommandDefaultsToShell() {
    #expect(ContainerRunner.resolvedCommand(interactive: true, command: []) == ["/bin/sh"])
  }

  @Test func nonInteractiveWithoutCommandUsesImageEntrypoint() {
    #expect(ContainerRunner.resolvedCommand(interactive: false, command: []) == [])
  }
}
