import Foundation

/// Quota observation must never start an interactive login or open another app.
/// The restriction is inherited by CLI children and fails closed if unavailable.
enum BackgroundCLI {
    static let profile = #"""
    (version 1)
    (allow default)
    (deny process-exec
        (literal "/usr/bin/open")
        (literal "/usr/bin/osascript")
        (regex #"/[^/]+\.app/Contents/MacOS/"))
    (deny appleevent-send)
    (deny mach-lookup (global-name-regex "^com\\.apple\\.lsd"))
    """#

    static func run(binary: URL, arguments: [String], environment: [String: String],
                    timeout: TimeInterval, cancelled: () -> Bool) throws -> Data {
        var environment = environment
        environment["BROWSER"] = "/usr/bin/false"
        return try QuotaProcess.run(binary: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile, binary.path] + arguments,
            environment: environment, timeout: timeout,
            currentDirectory: FileManager.default.temporaryDirectory, cancelled: cancelled)
    }
}
