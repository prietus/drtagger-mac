import Foundation

// Runs an external executable and collects its output. Both pipes are
// drained concurrently through readabilityHandler so a chatty child (ffmpeg
// writes its banner and progress to stderr) can never fill a pipe buffer and
// deadlock before it exits. Suitable for short commands whose full output
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
        try await withCheckedThrowingContinuation { continuation in
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

            let collector = OutputCollector()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData, to: .stdout)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData, to: .stderr)
            }

            process.terminationHandler = { proc in
                // Drain whatever is left after termination, then detach
                // the handlers so the pipes can close.
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), to: .stdout)
                collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), to: .stderr)
                let (out, err) = collector.snapshot()
                continuation.resume(returning: Result(status: proc.terminationStatus, stdout: out, stderr: err))
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: RunError.launchFailed(error.localizedDescription))
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
