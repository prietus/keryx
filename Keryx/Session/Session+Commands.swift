import Foundation
import KeryxProtocol

/// What the UI should do after a command ran.
enum CommandOutcome {
    case none
    case select(Buffer)
    case clear(Buffer)
    case closed(Buffer)
    case addHighlight([String])
    case removeHighlight([String])
    case listHighlights
    case editProfile
    /// Ask the system what's playing and send it as an action here.
    case nowPlaying(Buffer)
}

/// A slash command, for completion and the palette.
struct SlashCommand: Identifiable, Sendable {
    var name: String
    var usage: String
    var summary: String
    var id: String { name }

    static let all: [SlashCommand] = [
        .init(name: "join", usage: String(localized: "/join #channel [key]"), summary: String(localized: "Joins a channel; with no arguments, accepts the latest invitation.")),
        .init(name: "part", usage: String(localized: "/part [#channel] [reason]"), summary: String(localized: "Leaves a channel.")),
        .init(name: "close", usage: String(localized: "/close"), summary: String(localized: "Closes this conversation (and leaves it if it’s a channel).")),
        .init(name: "query", usage: String(localized: "/query nick [text]"), summary: String(localized: "Opens a private conversation.")),
        .init(name: "msg", usage: String(localized: "/msg target text"), summary: String(localized: "Sends a message without opening the conversation.")),
        .init(name: "me", usage: String(localized: "/me action"), summary: String(localized: "A stage direction in the third person.")),
        .init(name: "notice", usage: String(localized: "/notice target text"), summary: String(localized: "Sends a notice (NOTICE).")),
        .init(name: "nick", usage: String(localized: "/nick new"), summary: String(localized: "Changes your nick.")),
        .init(name: "setname", usage: String(localized: "/setname real name"), summary: String(localized: "Changes your real name (setname).")),
        .init(name: "topic", usage: String(localized: "/topic [text]"), summary: String(localized: "Shows or changes the channel’s topic.")),
        .init(name: "whois", usage: String(localized: "/whois nick"), summary: String(localized: "Someone’s profile.")),
        .init(name: "away", usage: String(localized: "/away [reason]"), summary: String(localized: "Marks you as away.")),
        .init(name: "back", usage: String(localized: "/back"), summary: String(localized: "Marks you as back.")),
        .init(name: "invite", usage: String(localized: "/invite nick [#channel]"), summary: String(localized: "Invites someone to the channel.")),
        .init(name: "kick", usage: String(localized: "/kick nick [reason]"), summary: String(localized: "Kicks someone from the channel.")),
        .init(name: "ban", usage: String(localized: "/ban mask"), summary: String(localized: "Bans a mask from the channel.")),
        .init(name: "unban", usage: String(localized: "/unban mask"), summary: String(localized: "Lifts a ban.")),
        .init(name: "op", usage: String(localized: "/op nick…"), summary: String(localized: "Gives operator.")),
        .init(name: "deop", usage: String(localized: "/deop nick…"), summary: String(localized: "Takes operator away.")),
        .init(name: "voice", usage: String(localized: "/voice nick…"), summary: String(localized: "Gives voice.")),
        .init(name: "devoice", usage: String(localized: "/devoice nick…"), summary: String(localized: "Takes voice away.")),
        .init(name: "mode", usage: String(localized: "/mode [target] modes"), summary: String(localized: "Changes modes.")),
        .init(name: "ignore", usage: String(localized: "/ignore [nick | mask | $a:account]"), summary: String(localized: "Hides someone (on soju, also blocks them).")),
        .init(name: "unignore", usage: String(localized: "/unignore nick"), summary: String(localized: "Stops ignoring.")),
        .init(name: "dim", usage: String(localized: "/dim [nick]"), summary: String(localized: "Dims someone without hiding them.")),
        .init(name: "undim", usage: String(localized: "/undim nick"), summary: String(localized: "Stops dimming.")),
        .init(name: "mute", usage: String(localized: "/mute [conversation]"), summary: String(localized: "Silences its notifications.")),
        .init(name: "unmute", usage: String(localized: "/unmute [conversation]"), summary: String(localized: "Notifies again.")),
        .init(name: "pin", usage: String(localized: "/pin [conversation]"), summary: String(localized: "Pins it to the top of the sidebar.")),
        .init(name: "unpin", usage: String(localized: "/unpin [conversation]"), summary: String(localized: "Unpins it.")),
        .init(name: "joins", usage: String(localized: "/joins"), summary: String(localized: "Shows or hides joins and parts here.")),
        .init(name: "buddy", usage: String(localized: "/buddy add|del|list nick"), summary: String(localized: "Contacts: tells you when they come online (MONITOR).")),
        .init(name: "highlight", usage: String(localized: "/highlight add|del word…"), summary: String(localized: "Words that mention you besides your nick.")),
        .init(name: "profile", usage: String(localized: "/profile [set key value | clear key]"), summary: String(localized: "Your profile: display name, pronouns, status… (draft/metadata-2).")),
        .init(name: "np", usage: String(localized: "/np"), summary: String(localized: "Shares what you’re listening to or watching (from the menu bar’s Now Playing).")),
        .init(name: "react", usage: String(localized: "/react emoji"), summary: String(localized: "Reacts to the latest message.")),
        .init(name: "delete", usage: String(localized: "/delete"), summary: String(localized: "Deletes your latest message (draft/message-redaction).")),
        .init(name: "ctcp", usage: String(localized: "/ctcp nick VERSION|PING|TIME"), summary: String(localized: "Sends a CTCP query.")),
        .init(name: "clear", usage: String(localized: "/clear"), summary: String(localized: "Clears this conversation’s view.")),
        .init(name: "caps", usage: String(localized: "/caps"), summary: String(localized: "Active IRCv3 capabilities.")),
        .init(name: "raw", usage: String(localized: "/raw line"), summary: String(localized: "Sends a line as is.")),
        .init(name: "quit", usage: String(localized: "/quit [reason]"), summary: String(localized: "Disconnects from this network.")),
        .init(name: "help", usage: String(localized: "/help"), summary: String(localized: "Lists the commands.")),
    ]
}

extension Session {
    /// Runs what the user typed: `/command …`, or a message (`//` escapes).
    func runInput(_ text: String, in buffer: Buffer, replyTo: String?) -> CommandOutcome {
        guard !text.isEmpty else { return .none }
        if text.hasPrefix("/"), !text.hasPrefix("//") { return runCommand(text, in: buffer) }
        sendMessage(text.hasPrefix("//") ? String(text.dropFirst()) : text, to: buffer, replyTo: replyTo)
        return .none
    }

    private func usage(_ name: String, in buffer: Buffer) {
        let text = SlashCommand.all.first { $0.name == name }?.usage ?? "/\(name)"
        note(String(localized: "Usage: \(text)"), in: buffer, kind: .error)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func runCommand(_ text: String, in buffer: Buffer) -> CommandOutcome {
        let body = text.dropFirst()
        let split = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = split.first.map { String($0).lowercased() } ?? ""
        let rest = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespaces) : ""
        let args = rest.split(separator: " ").map(String.init)
        let channel = buffer.kind == .channel ? buffer.name : nil

        switch cmd {
        case "join", "j":
            guard let target = args.first ?? lastInvite else { usage("join", in: buffer); return .none }
            for name in target.split(separator: ",").map(String.init) {
                let full = isupport.isChannel(name) ? name : "#" + name
                join(full, key: args.count > 1 ? args[1] : nil)
            }
            lastInvite = nil
            let first = target.split(separator: ",").first.map(String.init) ?? target
            let full = isupport.isChannel(first) ? first : "#" + first
            return self.buffer(named: full, kind: .channel, createIfMissing: true).map { .select($0) } ?? .none

        case "part", "leave":
            let target = args.first.flatMap { isupport.isChannel($0) ? $0 : nil } ?? channel
            guard let target else { usage("part", in: buffer); return .none }
            let reason = args.first.map { isupport.isChannel($0) } == true
                ? args.dropFirst().joined(separator: " ") : rest
            if let b = self.buffer(named: target, kind: .channel, createIfMissing: false) {
                part(b, reason: reason.isEmpty ? nil : reason)
                return .closed(b)
            }
            send(.part(target, reason: reason.isEmpty ? nil : reason))

        case "close":
            guard buffer.kind != .status else { return .none }
            part(buffer)
            return .closed(buffer)

        case "me":
            guard buffer.kind != .status, !rest.isEmpty else { usage("me", in: buffer); return .none }
            sendMessage(rest, to: buffer, action: true)

        case "msg", "privmsg":
            guard args.count >= 2 else { usage("msg", in: buffer); return .none }
            let message = String(rest.dropFirst(args[0].count + 1))
            let kind: Buffer.Kind = isupport.isChannel(args[0]) ? .channel : .query
            if let target = self.buffer(named: args[0], kind: kind, createIfMissing: kind == .query) {
                sendMessage(message, to: target)
            } else {
                send(.privmsg(args[0], message))
            }

        case "notice":
            guard args.count >= 2 else { usage("notice", in: buffer); return .none }
            send(.notice(args[0], String(rest.dropFirst(args[0].count + 1))))

        case "query", "q":
            guard let nick = args.first else { usage("query", in: buffer); return .none }
            let query = openQuery(nick)
            if args.count > 1 { sendMessage(String(rest.dropFirst(nick.count + 1)), to: query) }
            return .select(query)

        case "nick":
            guard let nick = args.first else { usage("nick", in: buffer); return .none }
            send(.nick(nick))

        case "setname":
            guard !rest.isEmpty else { usage("setname", in: buffer); return .none }
            if enabledCaps.contains(CapabilityName.setname) { send(.setname(rest)) }
            else { note(String(localized: "This server doesn’t allow changing your real name while connected."), in: buffer, kind: .error) }

        case "topic", "t":
            guard let channel else { usage("topic", in: buffer); return .none }
            if rest.isEmpty {
                note(buffer.topic.map { String(localized: "Topic: \($0)") } ?? String(localized: "This channel has no topic."), in: buffer)
            } else {
                send(IRCMessage(command: "TOPIC", parameters: [channel, rest]))
            }

        case "names":
            if let channel { send(.names(channel)) }

        case "whois", "wi":
            guard let nick = args.first ?? (buffer.kind == .query ? buffer.name : nil) else {
                usage("whois", in: buffer); return .none
            }
            requestWhois(nick)

        case "away":
            send(IRCMessage(command: "AWAY", parameters: rest.isEmpty ? [] : [rest]))
        case "back":
            send(IRCMessage(command: "AWAY"))

        case "invite":
            guard let nick = args.first, let target = args.count > 1 ? args[1] : channel else {
                usage("invite", in: buffer); return .none
            }
            send(IRCMessage(command: "INVITE", parameters: [nick, target]))

        case "kick", "k":
            guard let channel, let nick = args.first else { usage("kick", in: buffer); return .none }
            let reason = args.dropFirst().joined(separator: " ")
            send(IRCMessage(command: "KICK", parameters: [channel, nick] + (reason.isEmpty ? [] : [reason])))

        case "ban", "unban":
            guard let channel, let mask = args.first else { usage(cmd, in: buffer); return .none }
            let full = mask.contains("!") || mask.contains("@") ? mask : "\(mask)!*@*"
            send(IRCMessage(command: "MODE", parameters: [channel, cmd == "ban" ? "+b" : "-b", full]))

        case "op", "deop", "voice", "devoice":
            guard let channel, !args.isEmpty else { usage(cmd, in: buffer); return .none }
            let letter = cmd.hasSuffix("op") ? "o" : "v"
            let sign = cmd.hasPrefix("de") ? "-" : "+"
            let perLine = Int(isupport.tokens["MODES"] ?? "") ?? 3
            for start in stride(from: 0, to: args.count, by: max(1, perLine)) {
                let group = Array(args[start..<min(args.count, start + max(1, perLine))])
                send(IRCMessage(command: "MODE",
                                parameters: [channel, sign + String(repeating: letter, count: group.count)] + group))
            }

        case "mode":
            if args.isEmpty, let channel { send(IRCMessage(command: "MODE", parameters: [channel])) }
            else if let first = args.first, isupport.isChannel(first) || equal(first, currentNick) {
                send(IRCMessage(command: "MODE", parameters: args))
            } else if let channel {
                send(IRCMessage(command: "MODE", parameters: [channel] + args))
            }

        case "ignore":
            guard !rest.isEmpty else {
                note(state.ignores.isEmpty ? String(localized: "You’re not ignoring anyone on this network.")
                     : String(localized: "Ignored: \(state.ignores.map(\.pattern).formatted(.list(type: .and)))"), in: buffer)
                return .none
            }
            guard let mask = IgnoreMask(parsing: rest) else { usage("ignore", in: buffer); return .none }
            note(ignore(mask) ? String(localized: "Ignoring \(mask.pattern).") : String(localized: "You were already ignoring \(mask.pattern)."), in: buffer)

        case "unignore":
            guard let mask = IgnoreMask(parsing: rest) else { usage("unignore", in: buffer); return .none }
            note(unignore(mask) ? String(localized: "No longer ignoring \(mask.pattern).") : String(localized: "You weren’t ignoring \(mask.pattern)."), in: buffer)

        case "dim":
            guard let nick = args.first else {
                note(state.dimmed.isEmpty ? String(localized: "You’re not dimming anyone.")
                     : String(localized: "Dimmed: \(state.dimmed.formatted(.list(type: .and)))"),
                     in: buffer)
                return .none
            }
            setDimmed(true, nick)
            note(String(localized: "\(nick) will appear dimmed."), in: buffer)

        case "undim":
            guard let nick = args.first else { usage("undim", in: buffer); return .none }
            setDimmed(false, nick)
            note(String(localized: "\(nick) appears normally again."), in: buffer)

        case "mute", "unmute":
            let target = args.first ?? buffer.name
            setMuted(cmd == "mute", for: target)
            note(cmd == "mute" ? String(localized: "\(target) won’t notify you.") : String(localized: "\(target) will notify you again."), in: buffer)

        case "pin", "unpin":
            let target = args.first ?? buffer.name
            setPinned(cmd == "pin", for: target)

        case "joins":
            let quiet = !isPresenceQuiet(buffer.name)
            setPresenceQuiet(quiet, for: buffer.name)
            note(quiet ? String(localized: "Joins and parts are now hidden here.") : String(localized: "Joins and parts are shown here again."),
                 in: buffer)

        case "buddy", "monitor":
            let sub = args.first?.lowercased() ?? "list"
            let nicks = Array(args.dropFirst())
            switch sub {
            case "add", "+": nicks.forEach(addBuddy)
            case "del", "rm", "-": nicks.forEach(removeBuddy)
            case "clear": buddies.map(\.nick).forEach(removeBuddy)
            default:
                if !supportsMonitor { note(String(localized: "This server doesn’t support MONITOR."), in: buffer, kind: .error) }
                let list = buddies.map { $0.online == true ? String(localized: "\($0.nick) (online)") : $0.nick }
                note(buddies.isEmpty ? String(localized: "You have no contacts on this network.")
                     : String(localized: "Contacts: \(list.formatted(.list(type: .and)))"), in: buffer)
            }

        case "highlight":
            let sub = args.first?.lowercased() ?? ""
            let words = Array(args.dropFirst())
            switch sub {
            case "add": return .addHighlight(words)
            case "del", "rm": return .removeHighlight(words)
            default: return .listHighlights
            }

        case "profile":
            guard let sub = args.first?.lowercased() else { return .editProfile }
            let key = args.count > 1 ? args[1].lowercased() : ""
            guard Self.profileKeys.contains(key) else {
                note(String(localized: "Profile keys: \(Self.profileKeys.joined(separator: ", "))"), in: buffer, kind: .error)
                return .none
            }
            var profile = state.profile
            if sub == "set" {
                profile[key] = args.dropFirst(2).joined(separator: " ")
            } else if sub == "clear" {
                profile[key] = nil
            } else {
                return .editProfile
            }
            setProfile(profile)
            note(supportsProfile ? String(localized: "Profile updated.")
                 : String(localized: "Profile saved; this server doesn’t share profiles."), in: buffer)

        case "np", "nowplaying":
            guard buffer.kind != .status else { usage("np", in: buffer); return .none }
            return .nowPlaying(buffer)

        case "react":
            guard !rest.isEmpty,
                  let line = buffer.lines.last(where: { $0.msgid != nil && $0.kind.countsAsUnread }) else {
                usage("react", in: buffer); return .none
            }
            toggleReaction(rest, to: line, in: buffer)

        case "delete", "redact":
            guard networkAllowsRedaction else {
                note(String(localized: "This server doesn’t allow deleting messages."), in: buffer, kind: .error); return .none
            }
            let line = args.first.flatMap { id in buffer.lines.first { $0.msgid == id } }
                ?? buffer.lines.last { $0.isSelf && $0.msgid != nil && !$0.redacted }
            guard let line else { note(String(localized: "There’s no message of yours to delete."), in: buffer, kind: .error); return .none }
            redact(line, in: buffer, reason: args.count > 1 ? args.dropFirst().joined(separator: " ") : nil)

        case "ctcp":
            guard args.count >= 2 else { usage("ctcp", in: buffer); return .none }
            let request = args.dropFirst().joined(separator: " ").uppercased()
            send(.privmsg(args[0], "\u{01}\(request)\u{01}"))

        case "clear":
            return .clear(buffer)

        case "caps":
            note(String(localized: "Active capabilities: \(enabledCaps.sorted().joined(separator: ", "))"), in: buffer)

        case "raw", "quote":
            if let message = IRCMessage(parsing: rest) { send(message) }
            else { usage("raw", in: buffer) }

        case "quit", "disconnect":
            disconnect(message: rest.isEmpty ? "Keryx" : rest)

        case "help", "commands":
            note(SlashCommand.all.map(\.usage).joined(separator: "   "), in: buffer)

        default:
            // Unknown: hand it to the server, which may know it (services aliases, …).
            if let message = IRCMessage(parsing: String(body)) {
                send(message)
            }
        }
        return .none
    }
}
