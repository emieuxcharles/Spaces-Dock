import Foundation

/// A callback API may never reply, or reply after cancellation. Resolve it once.
@MainActor
public final class CallbackOperation<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?
    private var finished = false
    public init() {}
    public func run(timeout: Duration, start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        guard !finished else { throw CancellationError() }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for:timeout) } catch { return }
                    self?.complete(.failure(LayoutError.invalid("L’application n’a pas répondu dans le délai prévu. Elle peut encore s’ouvrir ; vérifie son état avant de réessayer.")))
                }
                start { result in self.complete(result) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    public func cancel() { complete(.failure(CancellationError())) }
    private func complete(_ result: Result<Value, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with:result); continuation = nil
        deadline?.cancel(); deadline = nil
    }
}
