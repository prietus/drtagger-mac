import Foundation

// Runs an external executable and collects its output. Both pipes are
// drained concurrently so a chatty child (ffmpeg writes its banner and
// progress to stderr) can never fill a pipe buffer and deadlock before it
// exits. Suitable for short commands whose full output
// fits in memory; streaming decode pipelines get their own runner later.
enum ProcessRunner {

    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    enum RunError: LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let msg): return "Could not launch process: \(msg)"
            }
        }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        // Pipes are read to end-of-file on their own threads, never with a
        // readabilityHandler, and the exit comes through the termination
        // handler (see ProcessLauncher in SplitKit).
        let collector = OutputCollector()
        let done = DispatchGroup()
        done.enter()
        process.terminationHandler = { _ in done.leave() }
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }
        for (handle, stream) in [(outPipe.fileHandleForReading, OutputCollector.Stream.stdout), (errPipe.fileHandleForReading, .stderr)] {
            done.enter()
            DispatchQueue.global(qos: .utility).async {
                collector.append(handle.readDataToEndOfFile(), to: stream)
                done.leave()
            }
        }
        return await withCheckedContinuation { continuation in
            done.notify(queue: .global(qos: .utility)) {
                let (out, err) = collector.snapshot()
                continuation.resume(returning: Result(status: process.terminationStatus, stdout: out, stderr: err))
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        enum Stream { case stdout, stderr }
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func append(_ data: Data, to stream: Stream) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            switch stream {
            case .stdout: out.append(data)
            case .stderr: err.append(data)
            }
        }

        func snapshot() -> (Data, Data) {
            lock.lock()
            defer { lock.unlock() }
            return (out, err)
        }
    }
}
