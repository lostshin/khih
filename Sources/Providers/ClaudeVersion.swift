import Foundation

/// The `User-Agent` the usage endpoint expects to see.
///
/// `GET /api/oauth/usage` is Claude Code's own call. Asked without its user
/// agent the request lands in a far stricter rate-limit bucket: on a real
/// account that meant a run of 429s and a reading that stopped moving for the
/// best part of a day, with nothing in the response to say why. Sending
/// `claude-code/<version>` is what makes the request look like the thing it is.
///
/// The version is read from the installed command every launch rather than
/// carried in the app: hard-coding one means claiming a version this Mac may
/// not have, and it would rot on its own.
enum ClaudeVersion {
    /// A bare `1.2.3`, or `1.2.3-beta.1`. Claude Code prints the version first
    /// and follows it with a parenthesised name, so the first match is the one.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\b"#)

    static func parse(_ output: String) -> String? {
        let range = NSRange(output.startIndex..., in: output)
        guard let match = pattern.firstMatch(in: output, range: range),
              let found = Range(match.range, in: output) else { return nil }
        return String(output[found])
    }

    /// `claude-code/<version>`, or nil where the command is missing or says
    /// something unrecognisable. Nil means the header is left off entirely —
    /// a made-up version is worse than none, and the request still works.
    static func userAgent(output: String) -> String? {
        parse(output).map { "claude-code/\($0)" }
    }

    /// Long enough for a cold Node start, short enough that a wedged process
    /// cannot hold the first reading open. Shorter than `ClaudeUsageCLI` uses
    /// because `--version` does no work.
    static let timeout: TimeInterval = 10

    static func run(binary: URL) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        // Never a terminal, for the same reason `/usage` is not given one.
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        try process.run()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return String(decoding: data, as: UTF8.self)
    }

    /// The production source: whichever standalone Claude Code is installed.
    static func installed() -> String? {
        guard let binary = ClaudeCLI.standalone() else { return nil }
        return (try? run(binary: binary)).flatMap(userAgent(output:))
    }
}
