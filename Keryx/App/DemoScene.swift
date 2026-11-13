#if DEBUG
import Foundation

/// `-KeryxDemo`: an offline scene for screenshots and design work. Nothing is
/// connected and nothing is written to disk.
extension AppModel {
    static var isDemo: Bool { CommandLine.arguments.contains("-KeryxDemo") }

    func makeDemoSession() -> Session {
        var config = SessionConfig(name: "Libera", host: "irc.libera.chat", nickname: "carlos")
        config.id = UUID(uuidString: "00000000-0000-0000-0000-00000000DE30")!
        let session = Session(config: config)
        let channel = session.buffer(named: "#swift", kind: .channel, createIfMissing: true)!
        channel.isJoined = true
        channel.topic = "Swift, SwiftUI y lo que venga. Sé amable; pega código en https://paste.example.org"
        channel.topicSetBy = "ana"
        channel.members = [
            Member(nick: "ana", prefixes: "@"), Member(nick: "teraflops", prefixes: "+"),
            Member(nick: "bob"), Member(nick: "carlos"), Member(nick: "zed", isAway: true),
            Member(nick: "helperbot", isBot: true),
        ]
        let start = Calendar.current.date(bySettingHour: 20, minute: 58, second: 0, of: .now)!
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        var lines: [ChatLine] = [
            ChatLine(timestamp: at(-1500), sender: "ana", text: "buenas noches a todos", kind: .message, msgid: "d0"),
            ChatLine(timestamp: at(0), sender: nil, text: "", kind: .event, direction: .join(nick: "teraflops")),
            ChatLine(timestamp: at(0.2), sender: nil, text: "", kind: .event, direction: .join(nick: "bob")),
            ChatLine(timestamp: at(0.3), sender: nil, text: "", kind: .event, direction: .quit(nick: "pepe", reason: nil)),
            ChatLine(timestamp: at(1), sender: "teraflops", text: "¿alguien ha probado ya el nuevo modelo de concurrencia estricta en un proyecto grande?", kind: .message, msgid: "d1"),
            ChatLine(timestamp: at(1.4), sender: "teraflops", text: "a mí me salen avisos de Sendable hasta en los tests", kind: .message, msgid: "d2"),
            ChatLine(timestamp: at(2), sender: "ana", text: "sí, lo migramos el mes pasado. La clave es marcar el modelo con @MainActor y dejar el transporte en un actor aparte", kind: .message, msgid: "d3"),
            ChatLine(timestamp: at(2.5), sender: "ana", text: "lo explican bien aquí: https://www.swift.org/migration/documentation/migrationguide/", kind: .message, msgid: "d4"),
            ChatLine(timestamp: at(3), sender: nil, text: "", kind: .event, direction: .mode(by: "ana", modes: "+v bob")),
            ChatLine(timestamp: at(4), sender: "bob", text: "gracias ana", kind: .message, msgid: "d5", reactions: ["👍": ["ana", "teraflops"]]),
            ChatLine(timestamp: at(5), sender: "bob", text: "se sirve otro café y abre Xcode", kind: .action, msgid: "d6"),
        ]
        var mention = ChatLine(timestamp: at(6), sender: "teraflops", text: "carlos: ¿tu cliente de IRC ya hace multiline?", kind: .message, msgid: "d7")
        mention.mentionsMe = true
        lines.append(mention)
        lines.append(ChatLine(timestamp: at(7), sender: "carlos", text: "sí, y draft/read-marker, chathistory y reacciones", kind: .message, isSelf: true, msgid: "d8", replyTo: "d7", reactions: ["🎉": ["teraflops", "carlos"]]))
        lines.append(ChatLine(timestamp: at(7.3), sender: "carlos", text: "las líneas salen a lápiz y pasan a tinta cuando el servidor las confirma", kind: .message, isSelf: true, isPending: true))
        var whisper = ChatLine(timestamp: at(7.4), sender: "helperbot", text: "tu turno de revisión en #swift es el jueves", kind: .notice, msgid: "w1", mentionsMe: true)
        whisper.whisper = true
        lines.append(whisper)
        let media = ProcessInfo.processInfo.environment["KERYX_DEMO_MEDIA"] ?? ""
        if media == "1" || media == "gif" {
            lines.append(ChatLine(timestamp: at(7.5), sender: "bob", text: "un gif: https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif", kind: .message, msgid: "m1"))
        }
        if media == "1" || media == "video" {
            lines.append(ChatLine(timestamp: at(7.6), sender: "ana", text: "y un vídeo https://download.samplelib.com/mp4/sample-5s.mp4", kind: .message, msgid: "m2"))
        }
        // A long scrollback, then a burst arriving just after the window opens
        // (what a busy channel does on reconnect).
        if let flood = ProcessInfo.processInfo.environment["KERYX_DEMO_FLOOD"].flatMap(Int.init) {
            let nicks = ["ana", "bob", "zed", "teraflops", "helperbot"]
            let old = (0..<flood).map { i in
                ChatLine(timestamp: start.addingTimeInterval(-Double(flood - i) * 40), sender: nicks[i % nicks.count],
                         text: "línea \(i) de relleno para un canal con mucho tráfico" + (i % 7 == 0 ? " y un poco más de texto para que ocupe dos renglones en la ventana, como pasa en los canales de verdad" : ""),
                         kind: .message, msgid: "f\(i)")
            }
            lines = old + lines
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                for i in 0..<6 {
                    channel.append(ChatLine(timestamp: Date().addingTimeInterval(Double(i)), sender: nicks[i % nicks.count],
                                            text: "ráfaga \(i)", kind: .message, msgid: "b\(i)", isHistorical: true), markUnread: false)
                }
            }
        }
        channel.lines = lines
        channel.readMarker = at(5.5)
        channel.recomputeUnread()
        channel.typing = ["ana": .now.addingTimeInterval(3600)]

        let query = session.buffer(named: "teraflops", kind: .query, createIfMissing: true)!
        query.peerOnline = true
        query.lines = [ChatLine(timestamp: at(3), sender: "teraflops", text: "oye, ¿me pasas el enlace del repo?", kind: .message)]
        query.unreadCount = 1
        _ = session.buffer(named: "#swift-es", kind: .channel, createIfMissing: true)
        session.status = .connected
        session.enabledCaps = ["message-tags", "echo-message", "draft/chathistory", "draft/multiline"]
        return session
    }
}
#endif
