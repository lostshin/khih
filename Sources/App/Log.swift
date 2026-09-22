import os

/// An agent app has no window to print into, so anything worth diagnosing has
/// to go somewhere you can read it:
///
///     log stream --predicate 'subsystem == "tw.lokun.khih"' --level debug
enum Log {
    static let usage = Logger(subsystem: "tw.lokun.khih", category: "usage")
    static let sessions = Logger(subsystem: "tw.lokun.khih", category: "sessions")
}
