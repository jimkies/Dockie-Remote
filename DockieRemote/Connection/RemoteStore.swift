import Observation
import UIKit

struct Banner: Equatable, Identifiable {
    enum Style { case warning, error, success }
    let id = UUID()
    let style: Style
    let text: String
    /// Sticky banners stay until tapped (displayOff).
    let sticky: Bool
}

struct ShareSession: Equatable, Identifiable {
    enum Phase { case starting, live }
    let id: String
    var phase: Phase
    let startedAt: Date
}

/// Lets the frame decoder reach the store without a retain cycle.
private final class WeakStore: @unchecked Sendable {
    weak var store: RemoteStore?
}

/// App state and the side of the connection that touches the world.
@MainActor
@Observable
final class RemoteStore {
    static let handshakeTimeout: TimeInterval = 10
    static let pingInterval: TimeInterval = 15
    static let silenceTimeout: TimeInterval = 35
    static let shareStartTimeout: TimeInterval = 10

    private(set) var pc: SavedPC?
    /// Shown on the Pair screen, e.g. after a 4001.
    var pairMessage: String?
    private(set) var machine = ConnectionMachine()
    private(set) var accounts: [Account] = []
    private(set) var images: [String: UIImage] = [:]
    private(set) var share: ShareSession?
    var banner: Banner?

    /// localNow − pcNow in ms, estimated from frame timestamps on this connection.
    private var clockOffsetMs: Int64?
    private var imageAt: [String: Int64] = [:]
    private var justPaired = false
    /// Bumped on every pairing change; decoded frames from an older session are dropped.
    @ObservationIgnored private var frameSession = 0

    @ObservationIgnored private var socket: WebSocketConnection?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastReceived = Date.distantPast
    @ObservationIgnored private var lastPing = Date.distantPast
    @ObservationIgnored private var openedAt = Date.distantPast
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var shareTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private let decoder: FrameDecoder

    init() {
        let box = WeakStore()
        decoder = FrameDecoder { frame in await box.store?.show(frame) }
        pc = PairingStore.load()
        machine = ConnectionMachine(hostCount: pc?.hosts.count ?? 1)
        box.store = self
    }

    var isConnected: Bool { machine.isConnected }

    var statusText: String {
        switch machine.state {
        case .connected: return "Connected"
        case .connecting, .handshaking: return "Connecting"
        case .backingOff: return "Reconnecting"
        case .idle, .rejected: return "Offline"
        }
    }

    // MARK: Lifecycle

    func enterForeground() {
        foreground = true
        if pc != nil { send(.start) }
    }

    func enterBackground() {
        foreground = false
        // The socket closes right away, so a stopShare would rarely get out. The PC ends the share when the socket closes.
        endShare(sendStop: false)
        send(.stop)
    }

    /// Pull to refresh: reconnect now, then wait briefly for the result.
    func refresh() async {
        guard pc != nil else { return }
        send(.refresh)
        for _ in 0..<20 {
            if isConnected { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Pairing

    func pair(with newPC: SavedPC) {
        send(.stop)
        PairingStore.save(newPC)
        pc = newPC
        pairMessage = nil
        justPaired = true
        resetSessionState()
        machine = ConnectionMachine(hostCount: newPC.hosts.count)
        if foreground { send(.start) }
    }

    func setAwayHost(_ host: String?) {
        guard var current = pc else { return }
        let trimmed = host?.trimmingCharacters(in: .whitespaces)
        current.awayHost = (trimmed?.isEmpty ?? true) ? nil : trimmed
        PairingStore.save(current)
        pc = current
        machine.hostCount = current.hosts.count
    }

    func forgetPC(message: String? = nil) {
        send(.stop)
        PairingStore.forget()
        pc = nil
        pairMessage = message
        resetSessionState()
        machine = ConnectionMachine()
    }

    private func resetSessionState() {
        endShare(sendStop: false)
        accounts = []
        images = [:]
        imageAt = [:]
        clockOffsetMs = nil
        frameSession += 1
        let decoder = self.decoder
        Task { await decoder.reset() }
    }

    // MARK: Sharing

    func startShare(_ account: Account) {
        guard isConnected, share == nil, account.canShare else { return }
        socket?.send(.share(id: account.id))
        share = ShareSession(id: account.id, phase: .starting, startedAt: .now)
        shareTimeoutTask?.cancel()
        shareTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.shareStartTimeout))
            guard !Task.isCancelled, let self, self.share?.id == account.id, self.share?.phase == .starting else { return }
            self.endShare(sendStop: true)
            self.showBanner(.error, "Couldn't start sharing. Try again.")
        }
    }

    /// For fullScreenCover(item:). Setting nil means the view was dismissed.
    var shareBinding: ShareSession? {
        get { share }
        set { if newValue == nil { stopShare() } }
    }

    /// Stop button, or the share view going away. Sends stopShare at most once.
    func stopShare() {
        endShare(sendStop: true)
    }

    private func endShare(sendStop: Bool) {
        shareTimeoutTask?.cancel()
        guard let current = share else { return }
        share = nil
        if sendStop, isConnected { socket?.send(.stopShare(id: current.id)) }
    }

    // MARK: Time

    /// Converts a PC timestamp to a local date using the estimated clock offset.
    func localDate(pcMillis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(pcMillis + (clockOffsetMs ?? 0)) / 1000)
    }

    // MARK: Banners

    func showBanner(_ style: Banner.Style, _ text: String, sticky: Bool = false) {
        let b = Banner(style: style, text: text, sticky: sticky)
        banner = b
        bannerTask?.cancel()
        guard !sticky else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.banner?.id == b.id else { return }
            self.banner = nil
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    // MARK: State machine plumbing

    private func send(_ event: ConnectionMachine.Event) {
        let wasConnected = machine.isConnected
        let effects = machine.handle(event)
        if wasConnected && !machine.isConnected { endShare(sendStop: false) }
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: ConnectionMachine.Effect) {
        switch effect {
        case .open(let hostIndex):
            openSocket(hostIndex: hostIndex)
        case .sendHello:
            if let token = pc?.token { socket?.send(.hello(token: token)) }
        case .close:
            closeSocket()
        case .scheduleRetry(let seconds):
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.send(.retryDue)
            }
        case .cancelRetry:
            retryTask?.cancel()
            retryTask = nil
        case .rejectPairing:
            forgetPC(message: justPaired
                     ? "Dockie didn't accept that token. Check it in Dockie and try again."
                     : "Pairing was reset on the PC. Pair again to reconnect.")
        }
    }

    private func openSocket(hostIndex: Int) {
        closeSocket()
        guard let url = pc?.url(hostIndex: hostIndex) else {
            // Never leave the machine waiting on a socket that doesn't exist: count it as a failed attempt.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.send(.closed(code: nil)) }
            }
            return
        }
        generation += 1
        let gen = generation
        clockOffsetMs = nil
        openedAt = .now
        lastReceived = .now
        let box = WeakStore()
        box.store = self
        let connection = WebSocketConnection(url: url) { event in
            // DispatchQueue.main keeps events in the order they arrived (an unstructured Task would not promise that).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.store?.handle(event, generation: gen) }
            }
        }
        socket = connection
        connection.open()
        startWatchdog()
    }

    private func closeSocket() {
        watchdogTask?.cancel()
        watchdogTask = nil
        socket?.close()
        socket = nil
        generation += 1
    }

    /// Handshake timeout, ping every 15 s, and the silence timeout.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.watchdogTick(now: .now)
            }
        }
    }

    private func watchdogTick(now: Date) {
        switch machine.state {
        case .connecting, .handshaking:
            if now.timeIntervalSince(openedAt) > Self.handshakeTimeout { send(.timedOut) }
        case .connected:
            if now.timeIntervalSince(lastReceived) > Self.silenceTimeout {
                send(.timedOut)
            } else if now.timeIntervalSince(lastPing) >= Self.pingInterval {
                lastPing = now
                socket?.send(.ping)
            }
        default:
            break
        }
    }

    fileprivate func handle(_ event: WebSocketConnection.Event, generation gen: Int) {
        guard gen == generation else { return } // a late callback from an old socket
        switch event {
        case .opened:
            send(.opened)
        case .closed(let code):
            send(.closed(code: code))
        case .message(let message):
            lastReceived = .now
            handle(message)
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let name):
            send(.welcome(pcName: name))
            lastPing = .now
            if justPaired {
                justPaired = false
                showBanner(.success, "Connected to \(name)")
            }
            if var current = pc, current.name != name, !name.isEmpty {
                current.name = name
                PairingStore.save(current)
                pc = current
            }
        case .accounts(let list):
            accounts = list
            let ids = Set(list.map(\.id))
            images = images.filter { ids.contains($0.key) }
            imageAt = imageAt.filter { ids.contains($0.key) }
            reconcileShare()
        case .frame(let frame):
            let sample = Int64(Date.now.timeIntervalSince1970 * 1000) - frame.at
            clockOffsetMs = min(clockOffsetMs ?? sample, sample)
            let decoder = self.decoder
            let session = frameSession
            Task { await decoder.submit(frame, session: session) }
        case .warning(let code, let text):
            showBanner(.warning, text, sticky: code == "displayOff")
        case .error(let id, let text):
            if let id, id == share?.id { endShare(sendStop: false) }
            showBanner(.error, text)
        case .pong, .unknown:
            break
        }
    }

    /// Opens or closes the share view from what the PC says.
    private func reconcileShare() {
        guard let current = share else { return }
        let state = accounts.first(where: { $0.id == current.id })?.state
        if state == .sharing {
            if current.phase == .starting {
                shareTimeoutTask?.cancel()
                share?.phase = .live
            }
        } else if current.phase == .live {
            // Ended on the PC: auto-stop, or the window was minimized, focused or restored there.
            endShare(sendStop: false)
        }
    }

    fileprivate func show(_ frame: DecodedFrame) {
        guard frame.session == frameSession else { return }
        if let shown = imageAt[frame.id], shown > frame.at { return }
        imageAt[frame.id] = frame.at
        images[frame.id] = frame.image
    }
}
