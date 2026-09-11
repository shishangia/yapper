import Foundation

@MainActor
final class NativeInferenceGate {
    static let shared = NativeInferenceGate()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        defer {
            if waiters.isEmpty {
                occupied = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation()
    }
}
