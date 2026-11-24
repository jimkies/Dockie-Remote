import Foundation

/// The JSON inside Dockie's pairing QR code.
struct PairingPayload: Decodable, Equatable, Sendable {
    let v: Int
    let host: String
    let port: Int
    let token: String
    let name: String

    enum ParseError: Error, Equatable {
        case notDockieCode
        case unsupportedVersion(Int)
        case invalidField(String)

        var message: String {
            switch self {
            case .notDockieCode: return "That isn't a Dockie pairing code."
            case .unsupportedVersion: return "This code is from a newer Dockie. Update Dockie Remote."
            case .invalidField(let f): return "The pairing code has an invalid \(f)."
            }
        }
    }

    static func parse(_ text: String) throws -> PairingPayload {
        guard let p = try? JSONDecoder().decode(PairingPayload.self, from: Data(text.utf8)) else {
            throw ParseError.notDockieCode
        }
        guard p.v == DockieProtocol.version else { throw ParseError.unsupportedVersion(p.v) }
        guard SavedPC.isValidHost(p.host) else { throw ParseError.invalidField("address") }
        guard (1...65535).contains(p.port) else { throw ParseError.invalidField("port") }
        guard !p.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseError.invalidField("token") }
        return p
    }

    var savedPC: SavedPC {
        SavedPC(host: host, port: port, token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                name: name.isEmpty ? host : name, awayHost: nil)
    }
}

/// The one paired PC, stored as a single Keychain item.
struct SavedPC: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var token: String
    var name: String
    /// Optional second address, normally the PC's Tailscale IP. Same port.
    var awayHost: String?

    /// Addresses tried in turn: home first, then away.
    var hosts: [String] {
        if let away = awayHost, !away.isEmpty, away != host { return [host, away] }
        return [host]
    }

    func url(hostIndex: Int) -> URL? {
        let list = hosts
        let h = list[hostIndex % list.count]
        var c = URLComponents()
        c.scheme = "ws"
        c.host = h
        c.port = port
        c.path = DockieProtocol.path
        return c.url
    }

    /// Hosts the app can actually reach under its ATS settings (see project.yml):
    /// an IPv4 address in a private or Tailscale range, or an unqualified or .local host name.
    /// IPv6 is not accepted (see design: resolution is IPv4 only).
    static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        if let octets = ipv4Octets(s) { return isAllowedIPv4(octets) }
        // Anything made only of digits and dots must have been a (bad) IPv4 address.
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let name = s.hasSuffix(".") ? String(s.dropLast()) : s
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        // ATS NSAllowsLocalNetworking covers "desk-pc" and "desk-pc.local" but not "desk-pc.lan".
        return labels.count == 1 || (labels.count == 2 && labels[1].lowercased() == "local")
    }

    /// A dotted-quad IPv4 address (no leading zeros) that the app's ATS exceptions allow.
    static func isIPv4(_ s: String) -> Bool {
        guard let octets = ipv4Octets(s) else { return false }
        return isAllowedIPv4(octets)
    }

    static func ipv4Octets(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  p.count == 1 || p.first != "0", let n = Int(p), n <= 255 else { return nil }
            octets.append(n)
        }
        return octets
    }

    /// 10/8, 172.16/12, 192.168/16 and Tailscale's 100.64/10, matching NSExceptionDomains in project.yml.
    static func isAllowedIPv4(_ o: [Int]) -> Bool {
        guard o.count == 4 else { return false }
        switch o[0] {
        case 10: return true
        case 172: return (16...31).contains(o[1])
        case 192: return o[1] == 168
        case 100: return (64...127).contains(o[1])
        default: return false
        }
    }
}
