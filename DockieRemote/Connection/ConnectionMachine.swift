import Foundation

/// Pure connection state machine. No I/O: `RemoteStore` performs the effects it returns.
struct ConnectionMachine: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case connecting(attempt: Int)
        case handshaking(attempt: Int)
        case connected(pcName: String)
        case backingOff(nextAttempt: Int)
        /// The PC rejected the token (close 4001). Nothing happens until a new pairing.
        case rejected
    }

    enum Event: Equatable, Sendable {
        case start
        case stop
        case refresh
        case opened
        case welcome(pcName: String)
        case closed(code: Int?)
        /// No welcome in time, or nothing received for too long.
        case timedOut
        case retryDue
    }

    enum Effect: Equatable, Sendable {
        case open(hostIndex: Int)
        case sendHello
        case close
        case scheduleRetry(seconds: Double)
        case cancelRetry
        case rejectPairing
    }

    static let backoff: [Double] = [1, 2, 5, 10]

    private(set) var state: State = .idle
    /// 1 for home only, 2 when an away address is set.
    var hostCount: Int

    init(hostCount: Int = 1) {
        self.hostCount = max(1, hostCount)
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    static func delay(afterFailedAttempt attempt: Int) -> Double {
        backoff[min(max(attempt, 0), backoff.count - 1)]
    }

    private func hostIndex(for attempt: Int) -> Int { attempt % max(1, hostCount) }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.rejected, _):
            return []

        case (.idle, .start), (.backingOff, .start):
            state = .connecting(attempt: 0)
            return [.cancelRetry, .open(hostIndex: 0)]

        case (_, .start):
            return []

        case (.idle, .stop):
            return []

        case (_, .stop):
            state = .idle
            return [.cancelRetry, .close]

        case (.idle, .refresh):
            return []

        case (_, .refresh):
            state = .connecting(attempt: 0)
            return [.cancelRetry, .close, .open(hostIndex: 0)]

        case (.connecting(let a), .opened):
            state = .handshaking(attempt: a)
            return [.sendHello]

        case (.handshaking, .welcome(let name)):
            state = .connected(pcName: name)
            return []

        case (.connected, .welcome(let name)):
            state = .connected(pcName: name)
            return []

        case (_, .closed(let code)) where code == DockieProtocol.badTokenCloseCode:
            guard state != .idle else { return [] }
            state = .rejected
            return [.cancelRetry, .close, .rejectPairing]

        case (.connecting(let a), .closed), (.handshaking(let a), .closed),
             (.connecting(let a), .timedOut), (.handshaking(let a), .timedOut):
            state = .backingOff(nextAttempt: a + 1)
            return [.close, .scheduleRetry(seconds: Self.delay(afterFailedAttempt: a))]

        case (.connected, .closed), (.connected, .timedOut):
            state = .backingOff(nextAttempt: 0)
            return [.close, .scheduleRetry(seconds: Self.delay(afterFailedAttempt: 0))]

        case (.backingOff(let n), .retryDue):
            state = .connecting(attempt: n)
            return [.open(hostIndex: hostIndex(for: n))]

        default:
            // Stale or out-of-order events (a late close while backing off, a retry after stop) change nothing.
            return []
        }
    }
}
