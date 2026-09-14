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

        let child = try spawn(binary: binary, arguments: arguments,
                              environment: environment, currentDirectory: currentDirectory)

        // Nonblocking descriptors let the deadline run even when the child is
        // silent, and drain both pipes before either can fill up.
        let descriptors = [child.stdout, child.stderr]
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        defer { for descriptor in descriptors { close(descriptor) } }
        func drain(_ descriptor: Int32, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<32 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stdout = Data(), stderr = Data()
        var status: Int32 = 0
        while wait(child.pid, status: &status, options: WNOHANG) == 0 {
            drain(descriptors[0], into: &stdout)
            drain(descriptors[1], into: &stderr)
            if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                // The child is its own process-group leader. Targeting the
                // negative id terminates helpers it spawned as well as the
                // direct process, so no quota request survives cancellation.
                _ = kill(-child.pid, SIGTERM)
                let grace = ProcessInfo.processInfo.systemUptime + 1
                while wait(child.pid, status: &status, options: WNOHANG) == 0
                        && ProcessInfo.processInfo.systemUptime < grace {
                    drain(descriptors[0], into: &stdout)
                    drain(descriptors[1], into: &stderr)
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if wait(child.pid, status: &status, options: WNOHANG) == 0 {
                    _ = kill(-child.pid, SIGKILL)
                    _ = wait(child.pid, status: &status, options: 0)
                }
                throw cancelled() ? CodexError.cancelled : CodexError.timedOut(binary.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drain(descriptors[0], into: &stdout)
        drain(descriptors[1], into: &stderr)

        let terminationStatus = exitStatus(status)
        guard terminationStatus == 0 else {
            throw Failure(status: terminationStatus,
                          detail: String(String(decoding: stderr, as: UTF8.self).suffix(2_000)))
        }
        return stdout
    }

    private struct Child {
        var pid: pid_t
        var stdout: Int32
        var stderr: Int32
    }

    /// `Process` offers no way to create a process group before `exec`; doing
    /// it from the parent afterwards races with `exec` and normally fails with
    /// EACCES. `posix_spawn` makes group creation part of the spawn itself.
    private static func spawn(binary: URL, arguments: [String], environment: [String: String],
                              currentDirectory: URL?) throws -> Child {
        var out = [Int32](repeating: -1, count: 2)
        var err = [Int32](repeating: -1, count: 2)
        guard pipe(&out) == 0 else { throw posixError(errno) }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw posixError(errno)
        }
        let input = open("/dev/null", O_RDONLY)
        guard input >= 0 else {
            close(out[0]); close(out[1]); close(err[0]); close(err[1])
            throw posixError(errno)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            close(input); close(out[1]); close(err[1])
        }

        posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, out[0])
        posix_spawn_file_actions_addclose(&actions, err[0])
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = [binary.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointer in
            withCStrings(env) { envPointer in
                posix_spawn(&pid, binary.path, &actions, &attributes,
                            argvPointer, envPointer)
            }
        }
        guard result == 0 else {
            close(out[0]); close(err[0])
            throw posixError(result)
        }
        return Child(pid: pid, stdout: out[0], stderr: err[0])
    }

    private static func withCStrings<Result>(_ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result) rethrows -> Result {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private static func wait(_ pid: pid_t, status: inout Int32, options: Int32) -> pid_t {
        while true {
            let result = waitpid(pid, &status, options)
            if result >= 0 || errno != EINTR { return result }
        }
    }
}
