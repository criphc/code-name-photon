import Foundation
import ServerControl

/// Consumes a `ChildProcessSupervisor.events` stream so tests can await transitions and captured
/// logs deterministically — no polling and no sleeps. Start it before `start()`; the stream is
/// single-subscription.
public final class SupervisorEventRecorder: @unchecked Sendable {
    private let state: State
    private let task: Task<Void, Never>

    public init(stream: AsyncStream<SupervisorEvent>) {
        let state = State()
        self.state = state
        self.task = Task {
            for await event in stream {
                state.record(event)
            }
            state.finish()
        }
    }

    deinit {
        task.cancel()
    }

    public func stop() {
        task.cancel()
    }

    public var events: [SupervisorEvent] {
        state.events
    }

    public var states: [SupervisorState] {
        state.events.compactMap { event in
            if case .stateChanged(let state) = event { return state }
            return nil
        }
    }

    public var logs: [LogLine] {
        state.events.compactMap { event in
            if case .log(let line) = event { return line }
            return nil
        }
    }

    public func waitForEventCount(_ count: Int) async {
        await state.wait { $0.count >= count }
    }

    public func waitForStateChangeCount(_ count: Int) async {
        await state.wait { events in
            events.reduce(into: 0) { total, event in
                if case .stateChanged = event { total += 1 }
            } >= count
        }
    }

    public func waitForLogCount(_ count: Int) async {
        await state.wait { events in
            events.reduce(into: 0) { total, event in
                if case .log = event { total += 1 }
            } >= count
        }
    }

    public func waitForTerminalState() async {
        await state.wait { events in
            events.contains { event in
                if case .stateChanged(let state) = event { return state.isTerminal }
                return false
            }
        }
    }

    private final class State: @unchecked Sendable {
        private struct Waiter {
            let predicate: @Sendable ([SupervisorEvent]) -> Bool
            let continuation: CheckedContinuation<Void, Never>
        }

        private let lock = NSLock()
        private var stored: [SupervisorEvent] = []
        private var waiters: [Waiter] = []
        private var finished = false

        var events: [SupervisorEvent] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ event: SupervisorEvent) {
            lock.lock()
            stored.append(event)
            var satisfied: [CheckedContinuation<Void, Never>] = []
            var remaining: [Waiter] = []
            for waiter in waiters {
                if waiter.predicate(stored) {
                    satisfied.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            waiters = remaining
            lock.unlock()
            for continuation in satisfied {
                continuation.resume()
            }
        }

        func finish() {
            lock.lock()
            finished = true
            let waiters = self.waiters
            self.waiters = []
            lock.unlock()
            for waiter in waiters {
                waiter.continuation.resume()
            }
        }

        func wait(until predicate: @escaping @Sendable ([SupervisorEvent]) -> Bool) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished || predicate(stored) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(predicate: predicate, continuation: continuation))
                lock.unlock()
            }
        }
    }
}
