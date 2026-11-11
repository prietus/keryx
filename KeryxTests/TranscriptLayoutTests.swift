import Testing
import Foundation
@testable import Keryx

@Suite("Transcript layout and stage directions")
struct TranscriptLayoutTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func say(_ nick: String, _ text: String, at seconds: TimeInterval) -> ChatLine {
        ChatLine(timestamp: base.addingTimeInterval(seconds), sender: nick, text: text, kind: .message)
    }

    func event(_ direction: Direction, at seconds: TimeInterval) -> ChatLine {
        ChatLine(timestamp: base.addingTimeInterval(seconds), sender: nil, text: "", kind: .event, direction: direction)
    }

    @Test("Consecutive lines from one speaker share a name; a gap breaks it")
    func grouping() {
        let lines = [say("ana", "a", at: 0), say("ana", "b", at: 30), say("bob", "c", at: 40), say("bob", "d", at: 1000)]
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        let continued = rows.compactMap { row -> Bool? in
            if case let .speech(_, continued) = row { return continued } else { return nil }
        }
        #expect(continued == [false, true, false, false])
    }

    @Test("A run of joins and parts folds into one direction")
    func presenceFolding() {
        let lines = [event(.join(nick: "ana"), at: 0), event(.join(nick: "bob"), at: 1),
                     event(.part(nick: "carla", reason: nil), at: 2), say("ana", "hola", at: 3)]
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        guard case let .presence(run) = rows[1] else { Issue.record("expected presence"); return }
        #expect(run.count == 3)
        #expect(StageWriter.presence(run) == "Enter ana and bob. Exit carla.")
    }

    @Test("The scene break sits before the first unread line and counts what follows")
    func sceneBreak() {
        var mention = say("bob", "me?", at: 20)
        mention.mentionsMe = true
        let lines = [say("ana", "viejo", at: 0), say("ana", "nuevo", at: 10), mention]
        var options = TranscriptLayout.Options()
        options.firstUnreadID = lines[1].id
        let rows = TranscriptLayout.rows(for: lines, options: options)
        #expect(rows.contains(.sceneBreak(unread: 2, mentions: 1)))
        let index = rows.firstIndex(of: .sceneBreak(unread: 2, mentions: 1))!
        guard case let .speech(after, continued) = rows[index + 1] else { Issue.record("expected speech"); return }
        #expect(after.text == "nuevo")
        #expect(!continued)
    }

    @Test("Nick changes of silent lurkers are left out")
    func lurkers() {
        let lines = [event(.nick(old: "lurker", new: "lurker_"), at: 0), say("ana", "hola", at: 1),
                     event(.nick(old: "ana", new: "anita"), at: 2)]
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        let directions = rows.flatMap(\.lines).compactMap(\.direction)
        #expect(directions == [.nick(old: "ana", new: "anita")])
    }

    @Test("Lists read naturally and cap long crowds")
    func lists() {
        #expect(StageWriter.list(["ana"]) == "ana")
        #expect(StageWriter.list(["ana", "bob", "carla"]) == "ana, bob, and carla")
        #expect(StageWriter.list(["a", "b", "c", "d", "e", "f"]) == "a, b, c, and 3 more")
        #expect(StageWriter.list(["Ana", "ana", "bob"]) == "Ana and bob")
    }

    @Test("Exits use the classic plural: Exeunt")
    func exeunt() {
        let lines = [event(.part(nick: "ana", reason: nil), at: 0), event(.part(nick: "bob", reason: nil), at: 1)]
        #expect(StageWriter.presence(lines) == "Exeunt ana and bob.")
    }

    @Test("Modes read as sentences when they're the common ones")
    func modes() {
        #expect(StageWriter.modeSentence(by: "ana", modes: "+o bob") == "ana makes bob operator.")
        #expect(StageWriter.modeSentence(by: "ana", modes: "+vv bob carla") == "ana gives bob and carla a voice.")
        #expect(StageWriter.modeSentence(by: "ana", modes: "+mt") == "ana sets modes +mt.")
    }

    @Test("IRC formatting: colours dropped, styles kept, links found")
    func formatting() {
        #expect(MessageFormatter.plain("\u{02}hola\u{02} \u{03}04,12rojo\u{03} fin") == "hola rojo fin")
        let formatted = MessageFormatter.format("mira https://example.org/a y https://x.y", size: 14)
        #expect(formatted.links.map(\.absoluteString) == ["https://example.org/a", "https://x.y"])
        #expect(String(formatted.text.characters) == "mira https://example.org/a y https://x.y")
    }
}

@Suite("Links")
struct LinkTests {
    @Test("Bare hostnames aren't links; written URLs are")
    func hostnames() {
        #expect(MessageLinks.detect(in: "*** Found your hostname: 111.red-81-36.dynamicip.example.net").isEmpty)
        #expect(MessageLinks.detect(in: "mira https://example.org y www.swift.org").count == 2)
    }
}

@Suite("Reply threads")
struct ReplyThreadTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func say(_ nick: String, _ text: String, at s: TimeInterval, id: String? = nil, to parent: String? = nil) -> ChatLine {
        ChatLine(timestamp: base.addingTimeInterval(s), sender: nick, text: text, kind: .message, msgid: id, replyTo: parent)
    }

    @Test("A reply moves under its original; replies to replies join the thread")
    func nesting() {
        let lines = [say("crimson", "but i think i can get use to it", at: 0, id: "a"),
                     say("barth", "test", at: 10, id: "b"),
                     say("teraflops", "it's okay", at: 20, id: "c", to: "a"),
                     say("crimson", "thanks", at: 30, id: "d", to: "c")]
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        let order = rows.flatMap { row -> [String] in
            switch row {
            case let .speech(line, _): return ["say:" + line.text]
            case let .reply(line): return ["reply:" + line.text]
            default: return []
            }
        }
        #expect(order == ["say:but i think i can get use to it", "reply:it's okay", "reply:thanks", "say:test"])
    }

    @Test("A reply far from its original stays where it arrived")
    func farReply() {
        var lines = [say("crimson", "original", at: 0, id: "a")]
        for n in 1...6 { lines.append(say("bob", "msg \(n)", at: TimeInterval(n), id: "m\(n)")) }
        lines.append(say("teraflops", "late answer", at: 10, id: "r", to: "a"))
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        #expect(!rows.contains { if case .reply = $0 { true } else { false } })
        guard case let .speech(last, _)? = rows.last else { Issue.record("expected speech last"); return }
        #expect(last.text == "late answer")
    }

    @Test("A reply long after its original still nests when nothing much came between")
    func lateReply() {
        let lines = [say("crimson", "original", at: 0, id: "a"), say("teraflops", "much later", at: 3600 * 3, id: "r", to: "a")]
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        #expect(rows.contains { if case .reply = $0 { true } else { false } })
    }

    @Test("A reply to something not loaded stays in place")
    func orphan() {
        let lines = [say("barth", "test", at: 0, id: "b"), say("ana", "yes", at: 10, id: "c", to: "zzz")]
        let rows = TranscriptLayout.rows(for: lines, options: .init())
        #expect(!rows.contains { if case .reply = $0 { true } else { false } })
    }

    @Test("The scene break still counts a nested unread reply")
    func breakCounts() {
        let lines = [say("crimson", "hola", at: 0, id: "a"), say("barth", "test", at: 10, id: "b"),
                     say("ana", "re", at: 20, id: "c", to: "a")]
        var options = TranscriptLayout.Options()
        options.firstUnreadID = lines[2].id
        let rows = TranscriptLayout.rows(for: lines, options: options)
        let index = rows.firstIndex(of: .sceneBreak(unread: 1, mentions: 0))
        #expect(index != nil)
        if let index, case let .reply(line) = rows[index + 1] { #expect(line.text == "re") } else { Issue.record("break not before the reply") }
    }
}

@Suite("Image wrapper pages")
struct WrapperTests {
    @Test("Magic numbers identify images served without a type")
    func magic() {
        #expect(LinkResolver.looksLikeImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
        #expect(LinkResolver.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(LinkResolver.looksLikeImage(Data("RIFF\0\0\0\0WEBP".utf8)))
        #expect(!LinkResolver.looksLikeImage(Data("<!doctype html>".utf8)))
    }

    @Test("A title that names an image file marks a wrapper page")
    func titles() {
        #expect(LinkResolver.titleNamesImage("Captura de pantalla 2026-10-29.png — paste"))
        #expect(!LinkResolver.titleNamesImage("Swift migration guide"))
    }

    @Test("The first <img> is resolved against the page")
    func firstImage() {
        let base = URL(string: "https://paste.priet.us/abc")!
        #expect(LinkResolver.firstImage(in: #"<html><body><img class="x" src="/i/abc.png"></body>"#, base: base)?.absoluteString
                == "https://paste.priet.us/i/abc.png")
    }
}

@Suite("Link cards")
struct LinkCardTests {
    @Test("Page metadata: OpenGraph first, then twitter:, then plain description")
    func metadata() {
        let html = """
        <html><head><title>Fallback</title>
        <meta property="og:title" content="Keryx &amp; friends">
        <meta name="description" content="Plain description">
        <meta property="og:image" content="/card.png">
        </head></html>
        """
        #expect(LinkResolver.meta("og:title", in: html) == "Keryx &amp; friends")
        #expect(LinkResolver.decodeEntities(LinkResolver.meta("og:title", in: html)!) == "Keryx & friends")
        #expect(LinkResolver.meta("og:description", in: html) == nil)
        #expect(LinkResolver.meta("description", in: html) == "Plain description")
        #expect(LinkResolver.meta("og:image", in: html) == "/card.png")
    }
}

@Suite("Video")
struct VideoTests {
    @Test("Durations read like a player's")
    func durations() {
        #expect(formattedDuration(42) == "0:42")
        #expect(formattedDuration(725) == "12:05")
        #expect(formattedDuration(3730) == "1:02:10")
    }

    @Test("Video pages are told apart by their metadata")
    func videoPages() {
        let html = #"<meta property="og:type" content="video.other"><meta property="og:video:duration" content="212">"#
        #expect(LinkResolver.meta("og:type", in: html) == "video.other")
        #expect(LinkResolver.meta("og:video:duration", in: html).flatMap(TimeInterval.init) == 212)
        #expect(MessageLinks.videoExtensions.contains("mp4"))
        #expect(!MessageLinks.videoExtensions.contains("webm"))
    }
}

@Suite("Durations")
struct ISODurationTests {
    @Test("ISO 8601 durations, as YouTube declares them")
    func iso() {
        #expect(LinkResolver.isoDuration("PT8M50S") == 530)
        #expect(LinkResolver.isoDuration("PT1H2M") == 3720)
        #expect(LinkResolver.isoDuration("P0DT0H3M1S") == 181)
        #expect(LinkResolver.isoDuration("PT0S") == nil)
        #expect(LinkResolver.isoDuration("8:50") == nil)
    }
}
