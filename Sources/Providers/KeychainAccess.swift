import Foundation
import Security

/// Serializes the process-wide legacy keychain interaction flag.
final class KeychainAccess: @unchecked Sendable {
    static let shared = KeychainAccess()
    private let lock = NSRecursiveLock()
    private let get: (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    private let set: (Bool) -> OSStatus

    init(get: @escaping (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus = SecKeychainGetUserInteractionAllowed,
         set: @escaping (Bool) -> OSStatus = SecKeychainSetUserInteractionAllowed) {
        self.get = get
        self.set = set
    }

    func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }

    func perform<T>(interactive: Bool = false, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var previous = DarwinBoolean(false)
        guard get(&previous) == errSecSuccess, set(interactive) == errSecSuccess else {
            throw UsageProviderError.accessDenied
        }
        defer { _ = set(previous.boolValue) }
        return try operation()
    }
}
