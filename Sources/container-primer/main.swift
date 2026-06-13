import Containerization
import ContainerizationOS
import Foundation

@main
struct ContainerPrimer {
    static func main() async throws {
        print("Starting container primer...")

        let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
        let kernelPath = "./vmlinux"
        print("Fetching base container filesystem...")
        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            network: try VmnetNetwork()
        )

        let containerId = "container-primer"
        let imageReference = "docker.io/library/python:3-alpine"
        let port = 8080

        print("Creating container from \(imageReference)...")

        let container = try await manager.create(
            containerId,
            reference: imageReference,
            rootfsSizeInBytes: 1.gib()
        ) { @Sendable config in
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            // Serve a tiny page with Python's built-in HTTP server (no install).
            // It stays in the foreground, keeping the container alive; output is
            // discarded since the host terminal is not attached.
            config.process.arguments = [
                "/bin/sh", "-c",
                "mkdir -p /www && echo '<h1>hello from container</h1>' > /www/index.html"
                    + " && python3 -m http.server \(port) --directory /www >/dev/null 2>&1",
            ]
            config.process.workingDirectory = "/"
        }

        defer {
            try? manager.delete(containerId)
        }

        print("Starting container...")
        try await container.create()
        try await container.start()

        if let interface = container.interfaces.first {
            let ip = interface.ipv4Address.address.description
            print("Server running at http://\(ip):\(port)")
        }
        print("Press Ctrl+C to stop.")

        // Run until the server exits or we receive SIGINT/SIGTERM. On signal we
        // stop the container, which lets wait() return and the deferred delete
        // tear the container down so nothing is persisted.
        let signals = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in signals.signals {
                    try? await container.stop()
                    return
                }
            }
            try await container.wait()
            group.cancelAll()
        }

        print("Container stopped, cleaning up.")
    }
}
