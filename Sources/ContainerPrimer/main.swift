import Containerization
import ContainerizationArchive
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
        let port = 8080

        // Host directory shared into the container over virtiofs. `make` runs from
        // the project root, so cwd/workspace is correct; an optional first argument
        // lets you point elsewhere (e.g. when running the binary from /var/tmp).
        let workspacePath =
            CommandLine.arguments.dropFirst().first
            ?? FileManager.default.currentDirectoryPath + "/workspace"
        guard FileManager.default.fileExists(atPath: workspacePath) else {
            fatalError("workspace directory not found: \(workspacePath)")
        }

        // Load the image from a locally built OCI archive instead of pulling from a
        // registry. Build it with `make image.tar` (see Makefile/Dockerfile).
        let imageTarPath = FileManager.default.currentDirectoryPath + "/image.tar"
        guard FileManager.default.fileExists(atPath: imageTarPath) else {
            fatalError("image archive not found: \(imageTarPath). Run `make image.tar`.")
        }

        print("Loading image from \(imageTarPath)...")

        // The archive is an OCI layout; extract it to a temp dir, then load into the
        // image store (mirrors `cctl image load`).
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primer-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: extractDir)
        }

        let reader = try ArchiveReader(file: URL(fileURLWithPath: imageTarPath))
        _ = try reader.extractContents(to: extractDir)

        let images = try await manager.imageStore.load(from: extractDir)
        guard let image = images.first else {
            fatalError("no image found in \(imageTarPath)")
        }

        print("Creating container from \(image.reference)...")

        let container = try await manager.create(
            containerId,
            image: image,
            rootfsSizeInBytes: 1.gib()
        ) { @Sendable config in
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            // Mount the host `workspace/` read-only; the image's baked-in server
            // serves it, so host edits there show up live.
            config.mounts.append(
                .share(source: workspacePath, destination: "/workspace", options: ["ro"]))
            config.process.arguments = ["python3", "/server.py", "\(port)"]
            config.process.workingDirectory = "/"
            // Forward an optional host env var into the container so server.py can
            // pick it up (demonstrates env passthrough).
            if let header = ProcessInfo.processInfo.environment["PRIMER_HEADER"] {
                config.process.environmentVariables.append("PRIMER_HEADER=\(header)")
            }
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
