import Foundation
import os

/// One WebSocket attempt. Create a new instance for every attempt; never reuse one.
/// JSON is decoded on the URLSession delegate queue, off the main thread.
final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case opened
        case message(ServerMessage)
        case closed(code: Int?)
    }

    /// Big enough for a base64 1080p JPEG. The URLSession default is 1 MB.
    static let maximumMessageSize = 16 * 1024 * 1024
    private static let log = Logger(subsystem: "dockie.remote", category: "socket")

    private let url: URL
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var didReportClose = false

    init(url: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.url = url
        self.onEvent = onEvent
        super.init()
    }

    func open() {
        let config = URLSessionConfiguration.ephemeral
        // Longer than the store's 35 s silence timeout: the store's watchdog owns liveness and the handshake timeout.
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageSize
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func send(_ message: ClientMessage) {
        let task = lock.withLock { self.task }
        task?.send(.string(message.jsonString())) { [weak self] error in
            if error != nil { self?.reportClose(code: nil) }
        }
    }

    /// Close politely (1001 going away) and drop all callbacks.
    func close() {
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            didReportClose = true
            defer { self.task = nil; self.session = nil }
            return (self.task, self.session)
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: Receive loop

    private func receiveNext() {
        let task = lock.withLock { self.task }
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.deliver(Data(text.utf8))
                self.receiveNext()
            case .success(.data(let data)):
                self.deliver(data)
                self.receiveNext()
            case .success:
                self.receiveNext()
            case .failure:
                let code = task?.closeCode ?? .invalid
                self.reportClose(code: code == .invalid ? nil : code.rawValue)
            }
        }
    }

    private func deliver(_ data: Data) {
        // A malformed message is dropped; it never tears down the connection. Never log the body: it can hold tokens and frames.
        let message: ServerMessage
        do { message = try ServerMessage.decode(data) } catch {
            Self.log.error("Dropped a malformed message (\(data.count) bytes): \(String(describing: error), privacy: .public)")
            return
        }
        if case .unknown = message { return }
        onEvent(.message(message))
    }

    private func reportClose(code: Int?) {
        let first = lock.withLock { () -> Bool in
            if didReportClose { return false }
            didReportClose = true
            return true
        }
        if first { onEvent(.closed(code: code)) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onEvent(.opened)
        receiveNext()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        reportClose(code: closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = (task as? URLSessionWebSocketTask)?.closeCode ?? .invalid
        reportClose(code: code == .invalid ? nil : code.rawValue)
    }
}
