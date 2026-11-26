import Foundation

/// Serializes fire-and-forget facade commands (`identify`, `track`, `reset`,
/// `report`) with awaited reads and fetches (`fetchCards`, `fetchMessages`,
/// `identifiedContact`, ...) so calls execute in call order.
@MainActor
public final class SequenzyCommandQueue {
    public typealias Command = @MainActor @Sendable () async -> Void
    private let continuation: AsyncStream<Command>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        self.continuation = continuation
        Task { @MainActor in
            for await command in stream {
                await command()
            }
        }
    }

    deinit {
        continuation.finish()
    }

    public func enqueue(_ command: @escaping Command) {
        continuation.yield(command)
    }

    public func enqueueAndWait<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { done in
            continuation.yield {
                let value = await operation()
                done.resume(returning: value)
            }
        }
    }

    public func enqueueAndWait<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            continuation.yield {
                do {
                    let value = try await operation()
                    done.resume(returning: value)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }
}
