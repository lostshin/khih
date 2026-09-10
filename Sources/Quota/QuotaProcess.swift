import Foundation
import Darwin

/// Running one provider command to completion, cancellably.
///
/// Shared by every provider because the requirements are the same for all of
/// them and getting any of them wrong is expensive: a command that outlives its
/// timeout holds the account's lock, and one whose pipe is not drained blocks
/// forever once it has written 64KB — a request that looks hung but has already
/// spent the quota.
enum QuotaProcess {
    struct Failure: Error, Equatable {
        var status: Int32
        /// The tail of stderr. Truncated because it is written to an activity
        /// log a person reads, not to a crash report.
        var detail: String
    }

    /// Standard output on success. A non-zero exit throws `Failure`; a timeout
    /// or a cancellation throws `CodexError`.
    static func run(binary: URL,
                    arguments: [String],
                    environment: [String: String],
                    timeout: TimeInterval,
                    currentDirectory: URL? = nil,
                    cancelled: () -> Bool = { false }) throws -> Data {
        if cancelled() { throw CodexError.cancelled }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        // Never a terminal: left inheriting the app's stdin, a command that
        // wants input waits for one that will never come.
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        // Nonblocking descriptors let the deadline run even when the child is
        // silent, and drain both pipes before either can fill up.
        let handles = [out.fileHandleForReading, err.fileHandleForReading]
        for handle in handles {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        defer { for handle in handles { try? handle.close() } }
        func drain(_ handle: FileHandle, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<32 {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stdout = Data(), stderr = Data()
        while process.isRunning {
            drain(handles[0], into: &stdout)
            drain(handles[1], into: &stderr)
            if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    drain(handles[0], into: &stdout)
                    drain(handles[1], into: &stderr)
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw cancelled() ? CodexError.cancelled : CodexError.timedOut(binary.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        drain(handles[0], into: &stdout)
        drain(handles[1], into: &stderr)

        guard process.terminationStatus == 0 else {
            throw Failure(status: process.terminationStatus,
                          detail: String(String(decoding: stderr, as: UTF8.self).suffix(2_000)))
        }
        return stdout
    }
}
