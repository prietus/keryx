import Testing
import Foundation
import KeryxProtocol
@testable import Keryx

/// Stands in for the network: records what the session sends and lets a
/// test feed server lines into it.
actor FakeTransport: IRCTransport {
    private var continuation: AsyncStream<IRCConnection.Event>.Continuation?
    private(set) var sent: [String] = []
    private(set) var endpoints: [IRCConnection.Endpoint] = []

    func open(_ endpoint: IRCConnection.Endpoint) -> AsyncStream<IRCConnection.Event> {
        endpoints.append(endpoint)
        let (stream, continuation) = AsyncStream<IRCConnection.Event>.makeStream()
        self.continuation = continuation
        continuation.yield(.ready)
        return stream
    }

    func send(_ message: IRCMessage) { sent.append(message.encoded()) }

    func disconnect() {
        continuation?.yield(.closed)
        continuation?.finish()
    }

    func receive(_ lines: String...) {
        for line in lines {
            guard let message = IRCMessage(parsing: line) else {
                Issue.record("unparseable test line: \(line)")
                continue
            }
            continuation?.yield(.message(message))
        }
    }
}

@MainActor
@Suite("Session", .serialized)
struct SessionTests {
    let transport = FakeTransport()
    let session: Session

    init() {
        session = Session(config: SessionConfig(host: "irc.test", useTLS: true, nickname: "me"), transport: transport)
    }

    @discardableResult
    func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func sent(_ line: String) async -> Bool {
        await eventually { await transport.sent.contains(line) }
    }

    func sent(where predicate: @escaping (String) -> Bool) async -> Bool {
        await eventually { await transport.sent.contains(where: predicate) }
    }

    func register(caps: String = "batch message-tags server-time echo-message labeled-response",
                  isupport: String = "CHANTYPES=# PREFIX=(ov)@+") async {
        session.connect()
        #expect(await sent("CAP LS 302"))
        await transport.receive(":srv CAP * LS :\(caps)", ":srv CAP * ACK :\(caps)",
                                ":srv 001 me :Welcome", ":srv 005 me \(isupport) :are supported")
        #expect(await eventually { session.status == .connected })
    }

    func channel(_ name: String = "#c") async -> Buffer? {
        await transport.receive(":me!u@h JOIN \(name)")
        _ = await eventually { session.buffers.contains { $0.name == name } }
        return session.buffers.first { $0.name == name }
    }

    @Test("Our line is pencil until the labelled echo turns it to ink")
    func pendingThenConfirmed() async throws {
        await register()
        let buffer = try #require(await channel())
        session.sendMessage("hola", to: buffer)
        let line = try #require(buffer.lines.last)
        #expect(line.isPending)
        let label = try #require(line.label)
        #expect(await sent("@label=\(label) PRIVMSG #c hola"))
        await transport.receive("@label=\(label);msgid=abc :me!u@h PRIVMSG #c hola")
        #expect(await eventually { buffer.lines.last?.isPending == false })
        #expect(buffer.lines.filter { $0.text == "hola" }.count == 1)
        #expect(buffer.lines.last?.msgid == "abc")
        #expect(buffer.lines.last?.id == line.id)
    }

    @Test("Without echo-message our line is final at once")
    func noEcho() async throws {
        await register(caps: "batch message-tags server-time")
        let buffer = try #require(await channel())
        session.sendMessage("hola", to: buffer)
        #expect(buffer.lines.last?.isPending == false)
    }

    @Test("Long lines are split under the byte limit, at spaces")
    func chunking() {
        let words = Array(repeating: "palabra", count: 120).joined(separator: " ")
        let chunks = Session.chunk(words, maxBytes: 100)
        #expect(chunks.allSatisfy { $0.utf8.count <= 100 })
        #expect(chunks.joined(separator: " ") == words)
        let emoji = String(repeating: "🎭", count: 60)
        let pieces = Session.chunk(emoji, maxBytes: 50)
        #expect(pieces.allSatisfy { $0.utf8.count <= 50 })
        #expect(pieces.joined() == emoji)
    }

    @Test("Multiline batches send continuation chunks with multiline-concat")
    func multilineSend() async throws {
        await register(caps: "batch message-tags server-time draft/multiline")
        let buffer = try #require(await channel())
        session.sendMessage("uno\ndos", to: buffer)
        #expect(await sent(where: { $0.hasPrefix("BATCH +ml1 draft/multiline #c") }))
        #expect(await sent("@batch=ml1 PRIVMSG #c uno"))
        #expect(await sent("@batch=ml1 PRIVMSG #c dos"))
        #expect(await sent("BATCH -ml1"))
    }

    @Test("Mode changes keep every prefix a member holds")
    func modeTracking() async throws {
        await register()
        let buffer = try #require(await channel())
        await transport.receive(":srv 353 me = #c :@+ana bob", ":srv 366 me #c :End")
        _ = await eventually { buffer.members.count == 2 }
        await transport.receive(":ana!a@h MODE #c +o-v bob ana")
        #expect(await eventually { buffer.members.first { $0.nick == "bob" }?.prefixes == "@" })
        #expect(buffer.members.first { $0.nick == "ana" }?.prefixes == "@")
        await transport.receive(":ana!a@h MODE #c +l 10")
        #expect(await eventually { buffer.lines.contains { $0.direction == .mode(by: "ana", modes: "+l 10") } })
    }

    @Test("A netsplit batch becomes one stage direction")
    func netsplit() async throws {
        await register()
        let buffer = try #require(await channel())
        await transport.receive(":srv 353 me = #c :ana bob", ":srv 366 me #c :End")
        _ = await eventually { buffer.members.count == 2 }
        await transport.receive(":srv BATCH +s1 netsplit a.net b.net",
                                "@batch=s1 :ana!a@h QUIT :a.net b.net",
                                "@batch=s1 :bob!b@h QUIT :a.net b.net",
                                ":srv BATCH -s1")
        #expect(await eventually {
            buffer.lines.contains { if case .split(_, let nicks, false)? = $0.direction { nicks.count == 2 } else { false } }
        })
        #expect(!buffer.lines.contains { if case .quit? = $0.direction { true } else { false } })
        #expect(buffer.members.isEmpty)
    }

    @Test("KICK, CHGHOST and ACCOUNT update the roster")
    func rosterEvents() async throws {
        await register()
        let buffer = try #require(await channel())
        await transport.receive(":srv 353 me = #c :ana bob", ":srv 366 me #c :End")
        _ = await eventually { buffer.members.count == 2 }
        await transport.receive(":ana!a@old CHGHOST newu new.host", ":ana!newu@new.host ACCOUNT ana_acc")
        #expect(await eventually { buffer.members.first { $0.nick == "ana" }?.host == "new.host" })
        #expect(await eventually { buffer.members.first { $0.nick == "ana" }?.account == "ana_acc" })
        await transport.receive(":ana!a@h KICK #c bob :fuera")
        #expect(await eventually { !buffer.members.contains { $0.nick == "bob" } })
        #expect(buffer.lines.contains { $0.direction == .kick(by: "ana", nick: "bob", reason: "fuera") })
    }

    @Test("A plaintext link with an STS policy reconnects over TLS on its port")
    func stsUpgrade() async throws {
        let plain = Session(config: SessionConfig(host: "sts.test", port: 6667, useTLS: false, nickname: "me"),
                            transport: transport)
        plain.connect()
        #expect(await sent("CAP LS 302"))
        await transport.receive(":srv CAP * LS :sts=port=6697 server-time")
        #expect(await eventually { await transport.endpoints.count == 2 })
        let second = try #require(await transport.endpoints.last)
        #expect(second.useTLS)
        #expect(second.port == 6697)
        plain.disconnect()
    }

    @Test("CHATHISTORY TARGETS opens queries for people who wrote while we were away")
    func targets() async throws {
        await register(caps: "batch message-tags server-time draft/chathistory")
        #expect(await sent(where: { $0.hasPrefix("CHATHISTORY TARGETS timestamp=") }))
        await transport.receive(":srv BATCH +t draft/chathistory-targets",
                                "@batch=t :srv CHATHISTORY TARGETS ana 2026-10-28T10:00:00.000Z",
                                "@batch=t :srv CHATHISTORY TARGETS #c 2026-10-28T10:00:00.000Z",
                                ":srv BATCH -t")
        #expect(await eventually { session.buffers.contains { $0.name == "ana" && $0.kind == .query } })
        #expect(!session.buffers.contains { $0.name == "#c" })
        #expect(await sent("CHATHISTORY LATEST ana * 100"))
    }

    @Test("A query follows its peer through a nick change")
    func queryRename() async throws {
        await register()
        await transport.receive(":ana!a@h PRIVMSG me :hola")
        #expect(await eventually { session.buffers.contains { $0.name == "ana" } })
        await transport.receive(":ana!a@h NICK anita")
        #expect(await eventually { session.buffers.contains { $0.name == "anita" } })
        #expect(!session.buffers.contains { $0.name == "ana" })
    }

    @Test("CTCP VERSION gets an answer; other CTCP is ignored")
    func ctcp() async throws {
        await register()
        await transport.receive(":ana!a@h PRIVMSG me :\u{01}VERSION\u{01}")
        #expect(await sent("NOTICE ana :\u{01}VERSION \(Session.version)\u{01}"))
        #expect(!session.buffers.contains { $0.name == "ana" })
    }

    @Test("Highlights match whole words only")
    func highlightWords() {
        session.highlightWords = { ["irkt"] }
        #expect(session.isHighlight("hola me, ¿qué tal?"))
        #expect(!session.isHighlight("meme"))
        #expect(session.isHighlight("prueba irkt"))
        #expect(!session.isHighlight("quirkt"))
    }
}

@MainActor
@Suite("Bouncer control connection", .serialized)
struct BouncerControlTests {
    @Test("The soju control connection doesn't JOIN configured channels")
    func noJoinOnControl() async {
        let transport = FakeTransport()
        var config = SessionConfig(host: "bnc.test", nickname: "me", isBouncer: true)
        config.autoJoinChannels = ["#libera"]
        let session = Session(config: config, transport: transport)
        session.connect()
        let opened = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < opened, await !transport.sent.contains("CAP LS 302") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let caps = "soju.im/bouncer-networks batch message-tags draft/chathistory"
        await transport.receive(":srv CAP * LS :\(caps)", ":srv CAP * ACK :\(caps)", ":srv 001 me :Welcome")
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline, session.status != .connected { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(100))
        let sent = await transport.sent
        #expect(sent.contains("BOUNCER LISTNETWORKS"))
        #expect(!sent.contains { $0.contains("JOIN #libera") })
        #expect(!sent.contains { $0.hasPrefix("CHATHISTORY TARGETS") })
    }
}

@MainActor
@Suite("File host")
struct FileHostTests {
    @Test("soju's FILEHOST gets the bare account, without @client or /network")
    func bareAccount() async {
        let transport = FakeTransport()
        let session = Session(config: SessionConfig(host: "bnc.test", nickname: "me", saslMode: .plain,
                                                    saslAccount: "carlos@keryx-abc/libera", saslPassword: "pw",
                                                    isBouncer: true), transport: transport)
        session.connect()
        let opened = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < opened, await !transport.sent.contains("CAP LS 302") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await transport.receive(":srv CAP * LS :batch", ":srv CAP * ACK :batch", ":srv 001 me :Welcome",
                                ":srv 005 me soju.im/FILEHOST=https://bnc.test/uploads :are supported")
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, session.fileHost == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.fileHost?.url.absoluteString == "https://bnc.test/uploads")
        #expect(session.fileHost?.basicUser == "carlos")
        #expect(session.fileHost?.basicPassword == "pw")
    }
}

@MainActor
@Suite("Unread while viewing", .serialized)
struct ViewingTests {
    @Test("Lines in the conversation you're viewing aren't unread; elsewhere they are")
    func viewing() async throws {
        let transport = FakeTransport()
        let session = Session(config: SessionConfig(host: "irc.test", nickname: "me"), transport: transport)
        session.connect()
        let opened = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < opened, await !transport.sent.contains("CAP LS 302") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await transport.receive(":srv CAP * LS :batch", ":srv CAP * ACK :batch", ":srv 001 me :Welcome",
                                ":me!u@h JOIN #seen", ":me!u@h JOIN #other")
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, session.buffers.count < 3 { try? await Task.sleep(for: .milliseconds(5)) }
        let seen = try #require(session.buffers.first { $0.name == "#seen" })
        let other = try #require(session.buffers.first { $0.name == "#other" })
        session.isViewing = { $0.id == seen.id }
        await transport.receive(":ana!a@h PRIVMSG #seen :hola me", ":ana!a@h PRIVMSG #other :hola me")
        let until = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < until, other.unreadCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(other.unreadCount == 1)
        #expect(other.hasMention)
        #expect(seen.unreadCount == 0)
        #expect(!seen.hasMention)
    }

    @Test("The scene break stays where you entered, as the live marker moves on")
    func sceneBreakStays() {
        let buffer = Buffer(name: "#c", kind: .channel)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        buffer.lines = [ChatLine(timestamp: t0, sender: "ana", text: "old", kind: .message),
                        ChatLine(timestamp: t0.addingTimeInterval(10), sender: "ana", text: "new", kind: .message)]
        buffer.readMarker = t0
        buffer.entryMarker = buffer.readMarker
        buffer.readMarker = t0.addingTimeInterval(10)   // marked read on entry
        #expect(buffer.firstUnreadID == nil)
        #expect(buffer.sceneBreakID == buffer.lines[1].id)
    }
}

@MainActor
@Suite("CTCP", .serialized)
struct CTCPTests {
    @Test("Replies show where you asked; PING reads as a round trip")
    func replies() async throws {
        let transport = FakeTransport()
        let session = Session(config: SessionConfig(host: "irc.test", nickname: "me"), transport: transport)
        session.connect()
        let opened = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < opened, await !transport.sent.contains("CAP LS 302") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await transport.receive(":srv CAP * LS :batch", ":srv CAP * ACK :batch", ":srv 001 me :Welcome", ":me!u@h JOIN #c")
        let ready = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < ready, !session.buffers.contains(where: { $0.name == "#c" }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let channel = try #require(session.buffers.first { $0.name == "#c" })
        _ = session.runInput("/ctcp ana version", in: channel, replyTo: nil)
        let sent = ContinuousClock.now + .seconds(2)
        let query = { (line: String) in line.hasPrefix("PRIVMSG ana ") && line.hasSuffix("\u{01}VERSION\u{01}") }
        while ContinuousClock.now < sent, await !transport.sent.contains(where: query) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.sent.contains(where: query))
        await transport.receive(":ana!a@h NOTICE me :\u{01}VERSION irssi 1.4.5\u{01}")
        let shown = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < shown, !channel.lines.contains(where: { $0.text.contains("irssi 1.4.5") }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(channel.lines.contains { $0.text.contains("VERSION") && $0.text.contains("irssi 1.4.5") })
        #expect(!session.buffers.contains { $0.name == "ana" })
    }
}

@MainActor
@Suite("Privacy mode")
struct PrivacyTests {
    @Test("Nicks named in a message are masked; links and other words aren't")
    func bodies() {
        let model = AppModel()
        model.preferences.privacyMode = true
        defer { model.preferences.privacyMode = false }
        let session = Session(config: SessionConfig(host: "irc.test", nickname: "me"))
        let buffer = Buffer(name: "#c", kind: .channel)
        buffer.members = [Member(nick: "sk1d"), Member(nick: "Ana")]
        let text = model.masked("ana: sk1d says hi, see https://x.y/ana", in: buffer, of: session)
        #expect(text == "\(model.shown("ana")): \(model.shown("sk1d")) says hi, see https://x.y/ana")
    }
}

@MainActor
@Suite("Test host")
struct TestHostTests {
    @Test("Under the tests the app loads no networks, so it never connects to yours")
    func noNetworks() {
        #expect(AppModel.isRunningTests)
        let model = AppModel()
        #expect(model.networks.isEmpty)
        #expect(model.sessions.isEmpty)
    }
}

// MARK: - Auto-away

extension SessionTests {

    @Test("Auto-away marks you away and back, only where it did")
    func autoAway() async throws {
        await register()
        let away = AutoAway(preferences: Preferences()) { [session] in [session] }
        away.apply(away: true)
        #expect(await sent { $0.hasPrefix("AWAY ") })
        await transport.receive(":srv 306 me :You have been marked as being away")
        #expect(await eventually { session.isAway })
        away.apply(away: true)  // still away: nothing more to say
        #expect(await transport.sent.filter { $0.hasPrefix("AWAY") }.count == 1)
        away.apply(away: false)
        #expect(await sent("AWAY"))
        #expect(away.marked.isEmpty)
    }

    @Test("Auto-away leaves an /away of your own alone")
    func autoAwayRespectsYours() async throws {
        await register()
        let buffer = session.statusBuffer
        _ = session.runInput("/away lunch", in: buffer, replyTo: nil)
        #expect(await sent("AWAY lunch"))
        await transport.receive(":srv 306 me :You have been marked as being away")
        #expect(await eventually { session.isAway })
        let away = AutoAway(preferences: Preferences()) { [session] in [session] }
        away.apply(away: true)
        away.apply(away: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sent.filter { $0.hasPrefix("AWAY") } == ["AWAY lunch"])
    }
}
