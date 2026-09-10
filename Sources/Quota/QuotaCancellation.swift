import Foundation

final class QuotaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}
