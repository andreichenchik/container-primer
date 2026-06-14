import Containerization
import ContainerizationOS
import Foundation

@main
struct ContainerPrimer {
    static func main() async throws {
        print("Starting container primer...")

        let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
        let kernelPath = "./.vmlinux"
        print("Fetching base container filesystem...")
        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            network: try VmnetNetwork()
        )

        // Unique per run so multiple instances can run in parallel.
        let containerId = "primer-\(UUID().uuidString)"
        let imageReference = "docker.io/library/python:3-alpine"
        let port = 8080

        // Host directory shared into the container over virtiofs. `make` runs from
        // the project root, so cwd/src is correct; an optional first argument lets
        // you point elsewhere (e.g. when running the binary from /var/tmp).
        let srcPath =
            CommandLine.arguments.dropFirst().first
            ?? FileManager.default.currentDirectoryPath + "/src"
        guard FileManager.default.fileExists(atPath: srcPath) else {
            fatalError("source directory not found: \(srcPath)")
        }

        print("Creating container from \(imageReference)...")

        let container = try await manager.create(
            containerId,
            reference: imageReference,
            rootfsSizeInBytes: 1.gib()
        ) { @Sendable config in
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            // Mount the host `src/` read-only and run the Python server from it.
            // The server serves src/public/, so host edits there show up live.
            config.mounts.append(.share(source: srcPath, destination: "/src", options: ["ro"]))
            config.process.arguments = ["python3", "/src/server.py", "\(port)"]
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
