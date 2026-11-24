import XCTest
@testable import DockieRemote

final class ProtocolTests: XCTestCase {

    // MARK: Client messages: exact JSON

    func testHelloEncoding() {
        XCTAssertEqual(ClientMessage.hello(token: "abc/123").jsonString(),
                       #"{"client":"ios","token":"abc/123","type":"hello","v":1}"#)
    }

    func testShareEncoding() {
        XCTAssertEqual(ClientMessage.share(id: "42").jsonString(), #"{"id":"42","type":"share"}"#)
    }

    func testStopShareEncoding() {
        XCTAssertEqual(ClientMessage.stopShare(id: "42").jsonString(), #"{"id":"42","type":"stopShare"}"#)
    }

    func testPingEncoding() {
        XCTAssertEqual(ClientMessage.ping.jsonString(), #"{"type":"ping"}"#)
    }

    func testClientMessagesRoundTripAsJSONObjects() throws {
        let hello = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ClientMessage.hello(token: "t").jsonString().utf8)) as? [String: Any])
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["token"] as? String, "t")
        XCTAssertEqual(hello["client"] as? String, "ios")
        XCTAssertEqual(hello["v"] as? Int, 1)
        XCTAssertEqual(hello.count, 4)
    }

    // MARK: Server messages

    func testWelcome() throws {
        XCTAssertEqual(try ServerMessage.decode(#"{"type":"welcome","pcName":"Gaming PC"}"#), .welcome(pcName: "Gaming PC"))
    }

    func testAccountsWithNullsAndAllStates() throws {
        let json = #"""
        {"type":"accounts","accounts":[
          {"id":"1","username":"alpha","displayName":"Alpha","state":"live","snapshotAt":null,"shareEndsAt":null},
          {"id":"2","username":"beta","displayName":"Beta","state":"minimized","snapshotAt":1700000000000,"shareEndsAt":null},
          {"id":"3","username":"gamma","displayName":"Gamma","state":"sharing","snapshotAt":null,"shareEndsAt":1700000060000},
          {"id":"4","username":"delta","displayName":"Delta","state":"offline"}
        ]}
        """#
        guard case .accounts(let list) = try ServerMessage.decode(json) else { return XCTFail("not accounts") }
        XCTAssertEqual(list.map(\.state), [.live, .minimized, .sharing, .offline])
        XCTAssertNil(list[0].snapshotAt)
        XCTAssertEqual(list[1].snapshotAt, 1_700_000_000_000)
        XCTAssertEqual(list[2].shareEndsAt, 1_700_000_060_000)
        XCTAssertNil(list[3].shareEndsAt)
        XCTAssertEqual(list[1].username, "beta")
        XCTAssertEqual(list.map(\.canShare), [true, true, false, false])
    }

    func testUnknownAccountStateBecomesOffline() throws {
        let json = #"{"type":"accounts","accounts":[{"id":"1","username":"a","displayName":"A","state":"teleporting","snapshotAt":null,"shareEndsAt":null}]}"#
        guard case .accounts(let list) = try ServerMessage.decode(json) else { return XCTFail() }
        XCTAssertEqual(list.first?.state, .offline)
    }

    func testFrameKinds() throws {
        for kind in ["preview", "snapshot", "share"] {
            let msg = try ServerMessage.decode(#"{"type":"frame","id":"7","kind":"\#(kind)","at":1700000000123,"jpeg":"/9j/AA=="}"#)
            XCTAssertEqual(msg, .frame(Frame(id: "7", kind: FrameKind(rawValue: kind)!, at: 1_700_000_000_123, jpeg: "/9j/AA==")))
        }
    }

    func testUnknownFrameKindIsIgnored() throws {
        let msg = try ServerMessage.decode(#"{"type":"frame","id":"7","kind":"hologram","at":1,"jpeg":""}"#)
        guard case .unknown = msg else { return XCTFail("expected unknown") }
    }

    func testWarning() throws {
        XCTAssertEqual(try ServerMessage.decode(#"{"type":"warning","code":"displayOff","message":"The PC display is off"}"#),
                       .warning(code: "displayOff", message: "The PC display is off"))
    }

    func testErrorWithAndWithoutId() throws {
        XCTAssertEqual(try ServerMessage.decode(#"{"type":"error","id":"3","message":"Window is offline"}"#),
                       .error(id: "3", message: "Window is offline"))
        XCTAssertEqual(try ServerMessage.decode(#"{"type":"error","id":null,"message":"Busy"}"#),
                       .error(id: nil, message: "Busy"))
    }

    func testPong() throws {
        XCTAssertEqual(try ServerMessage.decode(#"{"type":"pong"}"#), .pong)
    }

    func testUnknownTypeIsNotAnError() throws {
        XCTAssertEqual(try ServerMessage.decode(#"{"type":"executorStatus","foo":1}"#), .unknown(type: "executorStatus"))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ServerMessage.decode("not json"))
        XCTAssertThrowsError(try ServerMessage.decode(#"{"pcName":"x"}"#))
        XCTAssertThrowsError(try ServerMessage.decode(#"{"type":"welcome"}"#)) {
            XCTAssertEqual($0 as? ServerMessage.DecodeError, .missingField("pcName"))
        }
        XCTAssertThrowsError(try ServerMessage.decode(#"{"type":"frame","id":"1","kind":"preview","at":1}"#))
    }

    // MARK: Pairing

    func testValidQRPayload() throws {
        let p = try PairingPayload.parse(#"{"v":1,"host":"192.168.1.20","port":47821,"token":"s3cret","name":"Desk PC"}"#)
        XCTAssertEqual(p.savedPC, SavedPC(host: "192.168.1.20", port: 47821, token: "s3cret", name: "Desk PC", awayHost: nil))
        XCTAssertEqual(p.savedPC.url(hostIndex: 0)?.absoluteString, "ws://192.168.1.20:47821/v1")
    }

    func testQRPayloadRejections() {
        XCTAssertThrowsError(try PairingPayload.parse("https://example.com")) { XCTAssertEqual($0 as? PairingPayload.ParseError, .notDockieCode) }
        XCTAssertThrowsError(try PairingPayload.parse(#"{"v":2,"host":"192.168.1.2","port":1,"token":"t","name":"n"}"#)) {
            XCTAssertEqual($0 as? PairingPayload.ParseError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try PairingPayload.parse(#"{"v":1,"host":"999.1.1.1","port":47821,"token":"t","name":"n"}"#))
        XCTAssertThrowsError(try PairingPayload.parse(#"{"v":1,"host":"192.168.1.2","port":0,"token":"t","name":"n"}"#))
        XCTAssertThrowsError(try PairingPayload.parse(#"{"v":1,"host":"192.168.1.2","port":47821,"token":"  ","name":"n"}"#))
    }

    func testHostsAlternateWithAwayAddress() {
        var pc = SavedPC(host: "192.168.1.20", port: 47821, token: "t", name: "PC", awayHost: nil)
        XCTAssertEqual(pc.hosts, ["192.168.1.20"])
        pc.awayHost = "100.101.102.103"
        XCTAssertEqual(pc.hosts, ["192.168.1.20", "100.101.102.103"])
        XCTAssertEqual(pc.url(hostIndex: 1)?.absoluteString, "ws://100.101.102.103:47821/v1")
        XCTAssertEqual(pc.url(hostIndex: 2)?.absoluteString, "ws://192.168.1.20:47821/v1")
    }

    func testHostValidation() {
        XCTAssertTrue(SavedPC.isValidHost("10.0.0.1"))
        XCTAssertTrue(SavedPC.isValidHost("172.20.1.2"))
        XCTAssertTrue(SavedPC.isValidHost("192.168.1.20"))
        XCTAssertTrue(SavedPC.isValidHost("100.101.102.103"))
        XCTAssertTrue(SavedPC.isValidHost("desk-pc"))
        XCTAssertTrue(SavedPC.isValidHost("desk-pc.local"))
        XCTAssertFalse(SavedPC.isValidHost("desk-pc.lan"), "ATS blocks qualified names")
        XCTAssertFalse(SavedPC.isValidHost("mypc.tail1234.ts.net"), "MagicDNS names are blocked by ATS")
        XCTAssertFalse(SavedPC.isValidHost("8.8.8.8"), "public IPs are outside the ATS exceptions")
        XCTAssertFalse(SavedPC.isValidHost("169.254.10.10"), "link-local is outside the ATS exceptions")
        XCTAssertFalse(SavedPC.isValidHost("172.32.0.1"))
        XCTAssertFalse(SavedPC.isValidHost("100.128.0.1"))
        XCTAssertFalse(SavedPC.isValidHost("010.0.0.1"), "leading zeros can be read as octal")
        XCTAssertFalse(SavedPC.isValidHost("1.2.3"))
        XCTAssertFalse(SavedPC.isValidHost("256.0.0.1"))
        XCTAssertFalse(SavedPC.isValidHost("fe80::1"))
        XCTAssertFalse(SavedPC.isValidHost("a b"))
        XCTAssertFalse(SavedPC.isValidHost(""))
    }

    func testAwayAddressMustBeAllowedIPv4() {
        XCTAssertTrue(SavedPC.isIPv4("100.64.0.1"))
        XCTAssertFalse(SavedPC.isIPv4("desk-pc"))
        XCTAssertFalse(SavedPC.isIPv4("1.1.1.1"))
    }

    func testSavedPCRoundTripsThroughJSON() throws {
        let pc = SavedPC(host: "192.168.1.20", port: 47821, token: "t", name: "PC", awayHost: "100.64.0.1")
        let back = try JSONDecoder().decode(SavedPC.self, from: JSONEncoder().encode(pc))
        XCTAssertEqual(back, pc)
    }
}
