import Containerization
import ContainerizationArchive
import ContainerizationOS
import Foundation

/// Forwards container process output to a host file handle (stdout/stderr) so the
/// server's logs are visible on the host terminal.
final class HostWriter: @unchecked Sendable, Writer {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
    }
    func close() throws {}
}

@main
struct ContainerPrimer {
    /// Load `KEY=VALUE` pairs from a `.env` file in the current directory into the
    /// process environment. Existing environment variables take precedence, so the
    /// shell can still override `.env`. Missing file is a no-op.
    static func loadDotEnv() {
        let path = FileManager.default.currentDirectoryPath + "/.env"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
                (value.hasPrefix("\"") && value.hasSuffix("\""))
                    || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { setenv(key, value, 0) }
        }
    }

    static func main() async throws {
        loadDotEnv()
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
            // Mount the host `workspace/` read-only; the agent reads it live, so
            // host edits there are visible without a rebuild.
            config.mounts.append(
                .share(source: workspacePath, destination: "/workspace", options: ["ro"]))
            config.process.arguments = ["npx", "tsx", "/app/server.ts", "\(port)"]
            config.process.workingDirectory = "/app"
            // Surface the container's logs on the host terminal.
            config.process.stdout = HostWriter(.standardOutput)
            config.process.stderr = HostWriter(.standardError)
            // Forward the OpenAI-compatible endpoint config the agent needs.
            for key in ["OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAI_MODEL"] {
                if let value = ProcessInfo.processInfo.environment[key] {
                    config.process.environmentVariables.append("\(key)=\(value)")
                }
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
