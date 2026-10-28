import Testing
import Foundation
@testable import KeryxProtocol

@Suite("sasl-ir, NAK recovery and STS")
struct NegotiatorExtensionsTests {
    private func msg(_ line: String) throws -> IRCMessage {
        try #require(IRCMessage(parsing: line))
    }

    @Test("sasl-ir puts the PLAIN response on the opening AUTHENTICATE")
    func plainInitialResponse() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "alice", password: "pw"))
        _ = neg.start()
        _ = neg.handle(try msg(":srv CAP * LS :sasl=PLAIN draft/sasl-ir"))
        let auth = neg.handle(try msg(":srv CAP * ACK :sasl draft/sasl-ir"))
        let expected = SASL.initialResponse(for: .plain(authcid: "alice", password: "pw"))!.base64EncodedString()
        #expect(auth.map { $0.encoded() } == ["AUTHENTICATE PLAIN \(expected)"])
        // A stray `AUTHENTICATE +` must not make us send the response twice.
        #expect(neg.handle(try msg("AUTHENTICATE +")).isEmpty)
        #expect(neg.handle(try msg(":srv 903 alice :ok")).map { $0.encoded() } == ["CAP END"])
    }

    @Test("sasl-ir sends an empty EXTERNAL response as +")
    func externalInitialResponse() throws {
        var neg = CapabilityNegotiator(mechanism: .external())
        _ = neg.start()
        _ = neg.handle(try msg(":srv CAP * LS :sasl=EXTERNAL draft/sasl-ir"))
        let auth = neg.handle(try msg(":srv CAP * ACK :sasl draft/sasl-ir"))
        #expect(auth.map { $0.encoded() } == ["AUTHENTICATE EXTERNAL +"])
    }

    @Test("sasl-ir carries the SCRAM client-first, then the exchange continues")
    func scramInitialResponse() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "user", password: "pencil"),
                                       scramNonce: "rOprNGfwEbeRWgbNEkqO")
        _ = neg.start()
        _ = neg.handle(try msg(":srv CAP * LS :sasl=PLAIN,SCRAM-SHA-256 draft/sasl-ir"))
        let auth = neg.handle(try msg(":srv CAP * ACK :sasl draft/sasl-ir"))
        let first = try #require(auth.first)
        #expect(first.parameters.first == "SCRAM-SHA-256")
        let decoded = String(data: Data(base64Encoded: first.parameters[1])!, encoding: .utf8)
        #expect(decoded == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        // RFC 7677 server-first: the next reply is the client-final with a proof.
        let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        let final = neg.handle(try msg("AUTHENTICATE \(Data(serverFirst.utf8).base64EncodedString())"))
        let finalText = String(data: Data(base64Encoded: try #require(final.first?.parameters.first))!,
                               encoding: .utf8)
        #expect(finalText?.hasPrefix("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=") == true)
    }

    @Test("A NAKed REQ is retried cap by cap, keeping the ones granted")
    func nakSplitsRequest() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "a", password: "b"))
        _ = neg.start()
        _ = neg.handle(try msg(":srv CAP * LS :sasl=PLAIN server-time batch"))
        let retry = neg.handle(try msg(":srv CAP * NAK :batch sasl server-time"))
        #expect(retry.map { $0.encoded() } == ["CAP REQ batch", "CAP REQ sasl", "CAP REQ server-time"])
        #expect(neg.handle(try msg(":srv CAP * NAK :batch")).isEmpty)
        #expect(neg.handle(try msg(":srv CAP * ACK :server-time")).isEmpty)
        let auth = neg.handle(try msg(":srv CAP * ACK :sasl"))
        #expect(auth.map { $0.encoded() } == ["AUTHENTICATE PLAIN"])
        #expect(neg.enabled == ["sasl", "server-time"])
    }

    @Test("STS policy is parsed from the LS value and never requested")
    func stsPolicy() throws {
        var neg = CapabilityNegotiator()
        _ = neg.start()
        let req = neg.handle(try msg(":srv CAP * LS :sts=port=6697,duration=300,preload server-time"))
        #expect(req.first?.parameters[1] == "server-time")
        #expect(neg.stsPolicy == STSPolicy(port: 6697, duration: 300))
    }

    @Test("STS values: unknown keys ignored, empty rejected")
    func stsParsing() {
        #expect(STSPolicy(value: "duration=0") == STSPolicy(port: nil, duration: 0))
        #expect(STSPolicy(value: "port=6697,foo=bar") == STSPolicy(port: 6697, duration: nil))
        #expect(STSPolicy(value: "preload") == nil)
    }
}
