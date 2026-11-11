import Foundation

/// One row of the script as drawn.
enum TranscriptRow: Identifiable, Equatable {
    /// A new day: set as a dateline.
    case day(Date)
    /// The scene break (⁂) before the first unread line.
    case sceneBreak(unread: Int, mentions: Int)
    /// A line of dialogue. `continued` when the same speaker keeps talking,
    /// so the name isn't repeated.
    case speech(ChatLine, continued: Bool)
    /// An answer, set under the line it answers (`+reply`), the way irkt does:
    /// "↳ nick: text", without quoting the original that's right above.
    case reply(ChatLine)
    /// `/me`: a stage direction in the speaker's voice.
    case action(ChatLine)
    /// A run of joins/parts/quits/nick changes, folded into one direction.
    case presence([ChatLine])
    /// A single non-presence event (topic, kick, mode, invite).
    case event(ChatLine)
    /// Server text: status messages, MOTD, errors.
    case system(ChatLine)

    var id: String {
        switch self {
        case let .day(date): return "day-\(Int(date.timeIntervalSince1970))"
        case .sceneBreak: return "scene-break"
        case let .speech(line, _), let .reply(line), let .action(line), let .event(line), let .system(line):
            return line.id.uuidString
        case let .presence(lines): return "p-" + (lines.first?.id.uuidString ?? "")
        }
    }

    /// The lines this row draws, for find-in-conversation and jumps.
    var lines: [ChatLine] {
        switch self {
        case .day, .sceneBreak: return []
        case let .speech(line, _), let .reply(line), let .action(line), let .event(line), let .system(line): return [line]
        case let .presence(lines): return lines
        }
    }
}

enum TranscriptLayout {
    struct Options {
        var showPresence = true
        /// Hide a nick change unless that person spoke in the visible scrollback.
        var presenceOnlyForSpeakers = true
        var isHidden: (ChatLine) -> Bool = { _ in false }
        var firstUnreadID: UUID?
        var calendar = Calendar.current
        /// Lines from the same speaker within this interval share a name.
        var groupingInterval: TimeInterval = 5 * 60
        /// A reply is set under its original only when the original is this
        /// close — at most this many messages back, however long ago that
        /// was. Further away, moving it up would hide it, so it stays where
        /// it arrived, with a one-line quote of the original.
        var nestWithinMessages = 5
    }

    static func rows(for lines: [ChatLine], options: Options) -> [TranscriptRow] {
        let visible = lines.filter { !options.isHidden($0) }
        let speakers = options.presenceOnlyForSpeakers
            ? Set(visible.compactMap { $0.kind.countsAsUnread ? $0.sender?.lowercased() : nil })
            : []

        // Threads: a reply whose original is close by moves under it. Replies
        // to replies join the same thread, in the order they came. Distance is
        // counted in messages, so joins and parts in between don't matter.
        let messages = visible.filter(\.kind.countsAsUnread)
        var position: [String: Int] = [:]
        for (i, line) in messages.enumerated() {
            if let mid = line.msgid { position[mid] = i }
        }
        var thread: [String: [ChatLine]] = [:]
        var root: [String: String] = [:]
        var nested: Set<UUID> = []
        for (i, line) in messages.enumerated() {
            guard let parent = line.replyTo, let p = position[parent], p < i,
                  i - p <= options.nestWithinMessages
            else { continue }
            let top = root[parent] ?? parent
            thread[top, default: []].append(line)
            nested.insert(line.id)
            if let mid = line.msgid { root[mid] = top }
        }

        // The scene break goes before the first unread line that stays in place;
        // its counts cover every unread line, moved or not.
        let markerTime = options.firstUnreadID.flatMap { id in visible.first { $0.id == id }?.timestamp }
        var placedBreak = false

        var rows: [TranscriptRow] = []
        var lastDay: Date?
        var previous: ChatLine?
        var presenceRun: [ChatLine] = []

        func flushPresence() {
            guard !presenceRun.isEmpty else { return }
            rows.append(.presence(presenceRun))
            presenceRun = []
        }

        for line in visible where !nested.contains(line.id) {
            if let direction = line.direction, direction.isPresence {
                guard options.showPresence else { continue }
                if options.presenceOnlyForSpeakers, case let .nick(old, new) = direction,
                   !speakers.contains(old.lowercased()), !speakers.contains(new.lowercased()) { continue }
            }
            let day = options.calendar.startOfDay(for: line.timestamp)
            if lastDay != day {
                flushPresence()
                rows.append(.day(day))
                lastDay = day
                previous = nil
            }
            if !placedBreak, let markerTime, line.timestamp >= markerTime,
               line.id == options.firstUnreadID || (line.kind.countsAsUnread && !line.isSelf) {
                flushPresence()
                rows.append(.sceneBreak(unread: 0, mentions: 0))
                placedBreak = true
                previous = nil
            }

            if let direction = line.direction, direction.isPresence {
                presenceRun.append(line)
                previous = nil
                continue
            }
            flushPresence()
            switch line.kind {
            case .message, .notice:
                let continued = previous.map {
                    $0.sender == line.sender && $0.kind == line.kind && !$0.redacted
                        && line.timestamp.timeIntervalSince($0.timestamp) < options.groupingInterval
                        && line.replyTo == nil
                } ?? false
                rows.append(.speech(line, continued: continued))
                previous = line
            case .action:
                rows.append(.action(line))
                previous = nil
            case .event:
                rows.append(line.direction == nil ? .system(line) : .event(line))
                previous = nil
            case .error, .motd:
                rows.append(.system(line))
                previous = nil
            }
            if let mid = line.msgid, let replies = thread[mid] {
                for reply in replies {
                    if !placedBreak, let markerTime, reply.timestamp >= markerTime, !reply.isSelf {
                        rows.append(.sceneBreak(unread: 0, mentions: 0))
                        placedBreak = true
                    }
                    rows.append(.reply(reply))
                }
                previous = nil
            }
        }
        flushPresence()
        if let markerTime, let index = rows.firstIndex(where: { if case .sceneBreak = $0 { true } else { false } }) {
            let unread = visible.filter { $0.kind.countsAsUnread && !$0.isSelf && $0.timestamp >= markerTime }
            rows[index] = .sceneBreak(unread: unread.count, mentions: unread.filter(\.mentionsMe).count)
        }
        return rows
    }
}

/// Phrases stage directions the way a script would. In English the classic
/// forms ("Enter ana.", "Exeunt ana and bob."); in Spanish "Entra ana.",
/// "Salen ana y bob.". Keys are semantic because the two languages split
/// singular and plural differently.
enum StageWriter {
    /// "ana", "ana and bob", "ana, bob, and carla", "ana, bob, carla, and 4 more".
    static func list(_ names: [String], limit: Int = 4) -> String {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        guard unique.count > limit else { return unique.formatted(.list(type: .and)) }
        let rest = unique.count - (limit - 1)
        return (Array(unique.prefix(limit - 1)) + [String(localized: "presence.more", defaultValue: "\(rest) more")])
            .formatted(.list(type: .and))
    }

    private static func count(_ names: [String]) -> Int {
        Set(names.map { $0.lowercased() }).count
    }

    /// One sentence per kind of movement, in the order they first happened.
    static func presence(_ lines: [ChatLine]) -> String {
        var joins: [String] = [], parts: [String] = [], quits: [String] = []
        var partReason: String?, quitReason: String?
        var renames: [(String, String)] = []
        var splits: [String] = []
        var order: [String] = []
        func mark(_ kind: String) { if !order.contains(kind) { order.append(kind) } }
        for line in lines {
            switch line.direction {
            case let .join(n)?: joins.append(n); mark("join")
            case let .part(n, reason)?: parts.append(n); partReason = reason; mark("part")
            case let .quit(n, reason)?: quits.append(n); quitReason = reason; mark("quit")
            case let .nick(old, new)?: renames.append((old, new)); mark("nick")
            case let .split(servers, nicks, rejoined)?:
                let n = count(nicks)
                if rejoined {
                    splits.append(n == 1
                        ? String(localized: "presence.netjoin.one", defaultValue: "One person returns after a netsplit (\(servers)).")
                        : String(localized: "presence.netjoin.many", defaultValue: "\(n) people return after a netsplit (\(servers))."))
                } else {
                    splits.append(n == 1
                        ? String(localized: "presence.netsplit.one", defaultValue: "One person is lost in a netsplit (\(servers)).")
                        : String(localized: "presence.netsplit.many", defaultValue: "\(n) people are lost in a netsplit (\(servers))."))
                }
                mark("split")
            default: break
            }
        }
        var sentences: [String] = []
        for kind in order {
            switch kind {
            case "join":
                let who = list(joins)
                sentences.append(count(joins) == 1
                    ? String(localized: "presence.join.one", defaultValue: "Enter \(who).")
                    : String(localized: "presence.join.many", defaultValue: "Enter \(who)."))
            case "part":
                let who = list(parts)
                // A lone exit keeps its reason; a crowd doesn't.
                if parts.count == 1, let reason = partReason, !reason.isEmpty {
                    sentences.append(String(localized: "presence.part.reason", defaultValue: "Exit \(who) (“\(reason)”)."))
                } else {
                    sentences.append(count(parts) == 1
                        ? String(localized: "presence.part.one", defaultValue: "Exit \(who).")
                        : String(localized: "presence.part.many", defaultValue: "Exeunt \(who)."))
                }
            case "quit":
                let who = list(quits)
                if quits.count == 1, let reason = quitReason, !reason.isEmpty {
                    sentences.append(String(localized: "presence.quit.reason", defaultValue: "\(who) leaves the stage (“\(reason)”)."))
                } else {
                    sentences.append(count(quits) == 1
                        ? String(localized: "presence.quit.one", defaultValue: "\(who) leaves the stage.")
                        : String(localized: "presence.quit.many", defaultValue: "\(who) leave the stage."))
                }
            case "nick":
                sentences.append(renames.map { old, new in
                    String(localized: "presence.nick", defaultValue: "\(old), henceforth \(new).")
                }.joined(separator: " "))
            case "split":
                sentences.append(contentsOf: splits)
            default: break
            }
        }
        return sentences.joined(separator: " ")
    }

    /// A single event other than presence.
    static func event(_ direction: Direction) -> String {
        switch direction {
        case let .kick(by, nick, reason):
            if let reason, !reason.isEmpty {
                return String(localized: "event.kick.reason", defaultValue: "\(by) kicks \(nick) (“\(reason)”).")
            }
            return String(localized: "event.kick", defaultValue: "\(by) kicks \(nick).")
        case let .topic(by, text):
            return text.isEmpty
                ? String(localized: "event.topic.clear", defaultValue: "\(by) clears the topic.")
                : String(localized: "event.topic", defaultValue: "\(by) changes the topic.")
        case let .mode(by, modes):
            return modeSentence(by: by, modes: modes)
        case let .invite(by, nick, channel):
            return String(localized: "event.invite", defaultValue: "\(by) invites \(nick) to \(channel).")
        case let .setname(nick, name):
            return String(localized: "event.setname", defaultValue: "\(nick) now goes by “\(name)”.")
        case let .chghost(nick, user, host):
            let address = "\(user)@\(host)"
            return String(localized: "event.chghost", defaultValue: "\(nick) changes address to \(address).")
        case let .account(nick, account):
            if let account {
                return String(localized: "event.login", defaultValue: "\(nick) logs in as \(account).")
            }
            return String(localized: "event.logout", defaultValue: "\(nick) logs out.")
        case .join, .part, .quit, .nick, .split:
            return presence([ChatLine(timestamp: Date(), sender: nil, text: "", kind: .event, direction: direction)])
        }
    }

    /// `+o bob` reads as "ana makes bob an operator"; anything exotic stays literal.
    static func modeSentence(by: String, modes: String) -> String {
        let parts = modes.split(separator: " ").map(String.init)
        guard let flags = parts.first else {
            return String(localized: "mode.generic", defaultValue: "\(by) changes the modes.")
        }
        let targets = Array(parts.dropFirst())
        if flags.count >= 2, let sign = flags.first, Set(flags.dropFirst()).count == 1,
           let letter = flags.dropFirst().first, targets.count == flags.count - 1, !targets.isEmpty {
            let who = list(targets)
            switch (sign, letter) {
            case ("+", "o"): return String(localized: "mode.op", defaultValue: "\(by) makes \(who) operator.")
            case ("-", "o"): return String(localized: "mode.deop", defaultValue: "\(by) takes operator from \(who).")
            case ("+", "v"): return String(localized: "mode.voice", defaultValue: "\(by) gives \(who) a voice.")
            case ("-", "v"): return String(localized: "mode.devoice", defaultValue: "\(by) takes the voice from \(who).")
            case ("+", "h"): return String(localized: "mode.halfop", defaultValue: "\(by) makes \(who) half-operator.")
            case ("-", "h"): return String(localized: "mode.dehalfop", defaultValue: "\(by) takes half-operator from \(who).")
            case ("+", "b"): return String(localized: "mode.ban", defaultValue: "\(by) bans \(who).")
            case ("-", "b"): return String(localized: "mode.unban", defaultValue: "\(by) lifts the ban on \(who).")
            default: break
            }
        }
        return String(localized: "mode.set", defaultValue: "\(by) sets modes \(modes).")
    }
}
