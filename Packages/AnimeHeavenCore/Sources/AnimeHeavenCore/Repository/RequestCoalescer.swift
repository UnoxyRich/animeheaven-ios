import Foundation

/// Cancellation-safe request coalescer: launches shared fetches inside an unstructured detached
/// Task so cancelling one caller (e.g. a background preloader) never cancels the underlying fetch
/// for another foreground screen awaiting the same key.
public actor RequestCoalescer<Value: Sendable> {
    private var inFlight: [String: Task<Value, Error>] = [:]

    public init() {}

    public func getOrFetch(
        key: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task: Task<Value, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let created = Task.detached(priority: .userInitiated) {
                try await operation()
            }
            inFlight[key] = created
            task = created
            Task { [weak self] in
                _ = try? await created.value
                await self?.removeIfSame(key: key, task: created)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // Deliberately do NOT cancel `task`: other callers may still await it.
        }
    }

    private func removeIfSame(key: String, task: Task<Value, Error>) {
        if inFlight[key] == task {
            inFlight.removeValue(forKey: key)
        }
    }
}
