import Containerization
import ContainerizationOS
import Foundation

@main
struct ContainerPrimer {
    static func main() async throws {
        print("Starting container primer...")

        let current = try Terminal.current

        let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
        let kernelPath = "./vmlinux"
        print("Fetching base container filesystem...")
        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            network: try VmnetNetwork()
        )

        let containerId = "container-primer"
        let imageReference = "docker.io/library/alpine:3.16"

        print("Creating container from \(imageReference)...")

        let container = try await manager.create(
            containerId,
            reference: imageReference,
            rootfsSizeInBytes: 1.gib()
        ) { @Sendable config in
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            config.process.setTerminalIO(terminal: current)
            config.process.arguments = ["/bin/echo", "hello from container"]
            config.process.workingDirectory = "/"
        }

        defer {
            try? manager.delete(containerId)
        }

        print("Starting container...")
        try await container.create()
        try await container.start()

        let exitCode = try await container.wait()

        print("Container exited with code \(exitCode)")
        try await container.stop()
    }
}
