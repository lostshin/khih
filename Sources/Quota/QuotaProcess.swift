import Foundation

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

        let deadline = Date().addingTimeInterval(timeout)
        var stdout = Data(), stderr = Data()
        let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        while process.isRunning {
            if cancelled() || Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw cancelled() ? CodexError.cancelled : CodexError.timedOut(binary.lastPathComponent)
            }
            stdout.append(outHandle.availableData)
            stderr.append(errHandle.availableData)
        }
        stdout.append(outHandle.readDataToEndOfFile())
        stderr.append(errHandle.readDataToEndOfFile())

        guard process.terminationStatus == 0 else {
            throw Failure(status: process.terminationStatus,
                          detail: String(String(decoding: stderr, as: UTF8.self).suffix(2_000)))
        }
        return stdout
    }
}
