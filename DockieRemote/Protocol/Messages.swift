import Foundation

/// Protocol v1 shared with Dockie on the PC. Keep in sync with docs/design.md.
enum DockieProtocol {
    static let version = 1
    static let path = "/v1"
    static let bonjourType = "_dockie._tcp"
    static let defaultPort = 47821
    static let badTokenCloseCode = 4001
}

// MARK: - Client to server

/// Everything the app may ever send. There is deliberately no other case.
enum ClientMessage: Equatable, Sendable {
    case hello(token: String)
    case share(id: String)
    case stopShare(id: String)
    case ping

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a fixed struct of strings and ints cannot fail.
        let data = (try? encoder.encode(Wire(self))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private struct Wire: Encodable {
        let type: String
        var token: String?
        var client: String?
        var v: Int?
        var id: String?

        init(_ message: ClientMessage) {
            switch message {
            case .hello(let token):
                type = "hello"; self.token = token; client = "ios"; v = DockieProtocol.version
            case .share(let id):
                type = "share"; self.id = id
            case .stopShare(let id):
                type = "stopShare"; self.id = id
            case .ping:
                type = "ping"
            }
        }
    }
}

// MARK: - Server to client

enum AccountState: String, Sendable, Equatable {
    case live, minimized, sharing, offline
}

extension AccountState: Decodable {
    /// Unknown states from a newer Dockie decode as offline instead of failing the whole list.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccountState(rawValue: raw) ?? .offline
    }
}

struct Account: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let state: AccountState
    /// PC clock, Unix ms.
    let snapshotAt: Int64?
    /// PC clock, Unix ms.
    let shareEndsAt: Int64?

    var canShare: Bool { state == .live || state == .minimized }
}

enum FrameKind: String, Sendable, Equatable {
    case preview, snapshot, share
}

struct Frame: Sendable, Equatable {
    let id: String
    let kind: FrameKind
    /// PC clock, Unix ms.
    let at: Int64
    /// Base64 JPEG, decoded later off the main thread.
    let jpeg: String
}

enum ServerMessage: Equatable, Sendable {
    case welcome(pcName: String)
    case accounts([Account])
    case frame(Frame)
    case warning(code: String, message: String)
    case error(id: String?, message: String)
    case pong
    /// A type this version does not know. Ignored by the app.
    case unknown(type: String)

    enum DecodeError: Error, Equatable {
        case notJSON
        case missingType
        case missingField(String)
    }

    static func decode(_ text: String) throws -> ServerMessage {
        try decode(Data(text.utf8))
    }

    /// One JSON pass per message, so multi-megabyte frames are parsed once.
    static func decode(_ data: Data) throws -> ServerMessage {
        let w: Wire
        do { w = try JSONDecoder().decode(Wire.self, from: data) } catch { throw DecodeError.notJSON }
        guard let type = w.type else { throw DecodeError.missingType }
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw DecodeError.missingField(name) }
            return value
        }
        switch type {
        case "welcome":
            return .welcome(pcName: try need(w.pcName, "pcName"))
        case "accounts":
            return .accounts(try need(w.accounts, "accounts"))
        case "frame":
            let kindName = try need(w.kind, "kind")
            guard let kind = FrameKind(rawValue: kindName) else { return .unknown(type: "frame:\(kindName)") }
            return .frame(Frame(id: try need(w.id, "id"), kind: kind, at: try need(w.at, "at"), jpeg: try need(w.jpeg, "jpeg")))
        case "warning":
            return .warning(code: try need(w.code, "code"), message: w.message ?? "")
        case "error":
            return .error(id: w.id, message: try need(w.message, "message"))
        case "pong":
            return .pong
        default:
            return .unknown(type: type)
        }
    }

    /// Every field any server message can carry. Only the ones for `type` are read.
    private struct Wire: Decodable {
        let type: String?
        let pcName: String?
        let accounts: [Account]?
        let id: String?
        let kind: String?
        let at: Int64?
        let jpeg: String?
        let code: String?
        let message: String?
    }
}
