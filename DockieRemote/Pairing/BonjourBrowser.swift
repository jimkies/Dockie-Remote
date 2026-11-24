import Foundation
import Network
import dnssd
import Observation

struct DiscoveredPC: Identifiable, Hashable, @unchecked Sendable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Lists Dockie PCs on the local network (_dockie._tcp, TXT v=1) and resolves one to an IPv4 address.
@MainActor
@Observable
final class BonjourBrowser {
    private(set) var pcs: [DiscoveredPC] = []
    /// True when iOS reports that Local Network access was denied.
    private(set) var localNetworkDenied = false

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: DockieProtocol.bonjourType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            let denied: Bool
            if case .waiting(let error) = state, case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                denied = true
            } else {
                denied = false
            }
            Task { @MainActor [weak self] in self?.localNetworkDenied = denied }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredPC? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                if case .bonjour(let txt) = result.metadata, let v = txt["v"], v != String(DockieProtocol.version) { return nil }
                return DiscoveredPC(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in self?.pcs = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Opens a short TCP connection, restricted to IPv4, to learn the service's address and port.
    nonisolated static func resolve(_ pc: DiscoveredPC) async -> (host: String, port: Int)? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: pc.endpoint, using: params)
        let box = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(host: String, port: Int)?, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var result: (host: String, port: Int)?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let address) = host {
                        // Drop any "%en0" interface suffix.
                        let text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
                        result = (text, Int(port.rawValue))
                    }
                    connection.cancel()
                    if box.claim() { continuation.resume(returning: result) }
                case .failed, .waiting:
                    connection.cancel()
                    if box.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                connection.cancel()
                if box.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Makes sure a continuation is resumed once, whichever callback fires first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
