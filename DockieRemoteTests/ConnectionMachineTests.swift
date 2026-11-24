import XCTest
@testable import DockieRemote

final class ConnectionMachineTests: XCTestCase {

    private func connected(_ m: inout ConnectionMachine) {
        _ = m.handle(.start)
        _ = m.handle(.opened)
        _ = m.handle(.welcome(pcName: "PC"))
    }

    func testHappyPathSendsHelloThenConnectsOnWelcome() {
        var m = ConnectionMachine()
        XCTAssertEqual(m.handle(.start), [.cancelRetry, .open(hostIndex: 0)])
        XCTAssertEqual(m.state, .connecting(attempt: 0))
        XCTAssertEqual(m.handle(.opened), [.sendHello])
        XCTAssertEqual(m.state, .handshaking(attempt: 0))
        XCTAssertFalse(m.isConnected)
        XCTAssertEqual(m.handle(.welcome(pcName: "Desk")), [])
        XCTAssertEqual(m.state, .connected(pcName: "Desk"))
        XCTAssertTrue(m.isConnected)
    }

    func testBackoffSequenceIs1_2_5_10_then10() {
        var m = ConnectionMachine()
        _ = m.handle(.start)
        var delays: [Double] = []
        for _ in 0..<6 {
            let effects = m.handle(.closed(code: nil))
            for case .scheduleRetry(let s) in effects { delays.append(s) }
            _ = m.handle(.retryDue)
        }
        XCTAssertEqual(delays, [1, 2, 5, 10, 10, 10])
    }

    func testHandshakeTimeoutCountsAsFailedAttempt() {
        var m = ConnectionMachine()
        _ = m.handle(.start)
        _ = m.handle(.opened)
        XCTAssertEqual(m.handle(.timedOut), [.close, .scheduleRetry(seconds: 1)])
        XCTAssertEqual(m.state, .backingOff(nextAttempt: 1))
    }

    func testDropAfterWelcomeRetriesQuicklyFromAttemptZero() {
        var m = ConnectionMachine()
        connected(&m)
        XCTAssertEqual(m.handle(.closed(code: 1006)), [.close, .scheduleRetry(seconds: 1)])
        XCTAssertEqual(m.state, .backingOff(nextAttempt: 0))
        XCTAssertEqual(m.handle(.retryDue), [.open(hostIndex: 0)])
    }

    func testLivenessTimeoutWhileConnectedReconnects() {
        var m = ConnectionMachine()
        connected(&m)
        XCTAssertEqual(m.handle(.timedOut), [.close, .scheduleRetry(seconds: 1)])
    }

    func testAlternatesHomeAndAwayAddresses() {
        var m = ConnectionMachine(hostCount: 2)
        var hosts: [Int] = []
        for case .open(let i) in m.handle(.start) { hosts.append(i) }
        for _ in 0..<3 {
            _ = m.handle(.closed(code: nil))
            for case .open(let i) in m.handle(.retryDue) { hosts.append(i) }
        }
        XCTAssertEqual(hosts, [0, 1, 0, 1])
    }

    func testBadTokenRejectsAndStopsRetrying() {
        var m = ConnectionMachine()
        _ = m.handle(.start)
        _ = m.handle(.opened)
        XCTAssertEqual(m.handle(.closed(code: 4001)), [.cancelRetry, .close, .rejectPairing])
        XCTAssertEqual(m.state, .rejected)
        XCTAssertEqual(m.handle(.retryDue), [])
        XCTAssertEqual(m.handle(.start), [])
        XCTAssertEqual(m.handle(.refresh), [])
        XCTAssertEqual(m.state, .rejected)
    }

    func testBadTokenAfterWelcomeAlsoRejects() {
        var m = ConnectionMachine()
        connected(&m)
        XCTAssertEqual(m.handle(.closed(code: 4001)), [.cancelRetry, .close, .rejectPairing])
    }

    func testStopClosesAndCancelsFromAnyActiveState() {
        var m = ConnectionMachine()
        connected(&m)
        XCTAssertEqual(m.handle(.stop), [.cancelRetry, .close])
        XCTAssertEqual(m.state, .idle)

        _ = m.handle(.start)
        _ = m.handle(.closed(code: nil))
        XCTAssertEqual(m.handle(.stop), [.cancelRetry, .close])
        XCTAssertEqual(m.handle(.retryDue), [], "a retry that fires after stop does nothing")
        XCTAssertEqual(m.handle(.stop), [], "stopping twice does nothing")
    }

    func testStartWhileBackingOffConnectsNow() {
        var m = ConnectionMachine()
        _ = m.handle(.start)
        _ = m.handle(.closed(code: nil))
        _ = m.handle(.retryDue)
        _ = m.handle(.closed(code: nil))
        XCTAssertEqual(m.handle(.start), [.cancelRetry, .open(hostIndex: 0)])
        XCTAssertEqual(m.state, .connecting(attempt: 0))
    }

    func testStartWhileConnectedIsIgnored() {
        var m = ConnectionMachine()
        connected(&m)
        XCTAssertEqual(m.handle(.start), [])
    }

    func testRefreshReconnectsImmediately() {
        var m = ConnectionMachine()
        connected(&m)
        XCTAssertEqual(m.handle(.refresh), [.cancelRetry, .close, .open(hostIndex: 0)])
        XCTAssertEqual(m.state, .connecting(attempt: 0))
    }

    func testRefreshWhileIdleDoesNothing() {
        var m = ConnectionMachine()
        XCTAssertEqual(m.handle(.refresh), [])
    }

    func testStaleEventsAreIgnored() {
        var m = ConnectionMachine()
        XCTAssertEqual(m.handle(.opened), [])
        XCTAssertEqual(m.handle(.closed(code: nil)), [])
        XCTAssertEqual(m.handle(.closed(code: 4001)), [], "a late 4001 after stop does not wipe pairing")
        XCTAssertEqual(m.handle(.welcome(pcName: "x")), [])
        _ = m.handle(.start)
        _ = m.handle(.closed(code: nil))
        XCTAssertEqual(m.handle(.closed(code: nil)), [], "second close while backing off")
        XCTAssertEqual(m.handle(.welcome(pcName: "x")), [])
        XCTAssertEqual(m.state, .backingOff(nextAttempt: 1))
    }
}
