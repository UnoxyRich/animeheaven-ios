import Foundation

/// Cancellation-safe request coalescer: launches shared fetches inside an unstructured detached
/// Task so cancelling one caller (e.g. a background preloader) never cancels the underlying fetch
/// for another foreground screen awaiting the same key.
public actor RequestCoalescer<Value: Sendable> {
    private struct Flight {
        var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    }
    private var inFlight: [String: Flight] = [:]

    public init() {}

    public func getOrFetch(
        key: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let waiter = UUID()
        let value: Value = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let shouldStart = inFlight[key] == nil
                inFlight[key, default: Flight()].waiters[waiter] = continuation
                if shouldStart {
                    Task.detached(priority: .userInitiated) { [self] in
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        await finish(key: key, result: result)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter, key: key) }
        }
        try Task.checkCancellation()
        return value
    }

    private func cancelWaiter(_ waitId: UUID, key: String) {
        inFlight[key]?.waiters.removeValue(forKey: waitId)?.resume(throwing: CancellationError())
    }

    private func finish(key: String, result: Result<Value, Error>) {
        if let flight = inFlight.removeValue(forKey: key) {
            for waiter in flight.waiters.values { waiter.resume(with: result) }
        }
    }

    func waiterCount(for key: String) -> Int {
        inFlight[key]?.waiters.count ?? 0
    }
}
