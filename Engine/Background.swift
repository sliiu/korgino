import Foundation

/// Hop off the caller's actor (often MainActor) for CPU / I/O / network work.
enum Background {
    /// Cancelling the caller cancels the detached work too, so a dropped request stops its network call.
    static func run<T: Sendable>(
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: op)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func run<T: Sendable>(
        _ op: @Sendable @escaping () async -> T
    ) async -> T {
        let task = Task.detached(priority: .userInitiated, operation: op)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func runSync<T: Sendable>(
        _ op: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try op()
        }.value
    }

    static func runSync<T: Sendable>(
        _ op: @Sendable @escaping () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) {
            op()
        }.value
    }
}
