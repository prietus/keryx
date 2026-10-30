import Foundation
import Observation

/// Something that happened on stage rather than something said: rendered as a
/// stage direction. Kept structured (not pre-formatted text) so the transcript
/// can phrase it, and fold runs of joins/parts into one direction.
enum Direction: Codable, Sendable, Equatable {
    case join(nick: String)
    case part(nick: String, reason: String?)
    case quit(nick: String, reason: String?)
    case nick(old: String, new: String)
    case kick(by: String, nick: String, reason: String?)
    case topic(by: String, text: String)
    case mode(by: String, modes: String)
    case invite(by: String, nick: String, channel: String)
    case setname(nick: String, name: String)
    case chghost(nick: String, user: String, host: String)
    case account(nick: String, account: String?)
    /// A server split or rejoin (IRCv3 `netsplit` / `netjoin` batches),
    /// summarising every QUIT/JOIN inside it.
    case split(servers: String, nicks: [String], rejoined: Bool)

    /// The nick this event is about, for ignores and "only people who talk".
    var subject: String? {
        switch self {
        case let .join(n), let .part(n, _), let .quit(n, _), let .setname(n, _),
             let .chghost(n, _, _), let .account(n, _):
            return n
        case let .nick(_, new): return new
        case let .kick(_, n, _): return n
        case let .topic(by, _), let .mode(by, _), let .invite(by, _, _): return by
        case .split: return nil
        }
    }

    /// Joins, parts, quits and nick changes: the churn people choose to hide.
    var isPresence: Bool {
        switch self {
        case .join, .part, .quit, .nick, .split: return true
        default: return false
        }
    }
}

/// A rendered line in a buffer.
struct ChatLine: Identifiable, Sendable, Codable, Equatable {
    enum Kind: String, Sendable, Codable {
        case message, notice, action, event, error, motd

        var countsAsUnread: Bool {
            switch self {
            case .message, .notice, .action: return true
            case .event, .error, .motd: return false
            }
        }
    }

    let id: UUID
    var timestamp: Date
    var sender: String?
    var text: String
    var kind: Kind
    var isSelf: Bool
    var account: String?
    /// IRCv3 `msgid`: chathistory paging, reactions, replies, redaction.
    var msgid: String?
    /// `+reply` / `+draft/reply`: the msgid this line answers.
    var replyTo: String?
    /// emoji → nicks who reacted.
    var reactions: [String: Set<String>]
    var redacted: Bool
    var redactedBy: String?
    var redactionReason: String?
    var direction: Direction?
    var isHistorical: Bool
    var sourceUser: String?
    var sourceHost: String?
    /// Our own line, sent but not yet echoed back by the server
    /// (`echo-message`): drawn in graphite until confirmed.
    var isPending: Bool
    /// `labeled-response` label of the PRIVMSG we sent, to match its echo.
    var label: String?
    /// Whether this line mentions us (nick or highlight word).
    var mentionsMe: Bool

    init(id: UUID = UUID(), timestamp: Date, sender: String?, text: String,
         kind: Kind, isSelf: Bool = false, account: String? = nil,
         msgid: String? = nil, replyTo: String? = nil,
         reactions: [String: Set<String>] = [:], direction: Direction? = nil,
         isHistorical: Bool = false, sourceUser: String? = nil, sourceHost: String? = nil,
         isPending: Bool = false, label: String? = nil, mentionsMe: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.text = text
        self.kind = kind
        self.isSelf = isSelf
        self.account = account
        self.msgid = msgid
        self.replyTo = replyTo
        self.reactions = reactions
        self.redacted = false
        self.redactedBy = nil
        self.redactionReason = nil
        self.direction = direction
        self.isHistorical = isHistorical
        self.sourceUser = sourceUser
        self.sourceHost = sourceHost
        self.isPending = isPending
        self.label = label
        self.mentionsMe = mentionsMe
    }

    /// Who the line is "about", for ignore matching.
    var subjectNick: String? { sender ?? direction?.subject }
}

struct Member: Identifiable, Sendable, Hashable {
    var nick: String
    /// Every membership prefix held, highest first (`multi-prefix`).
    var prefixes: String = ""
    var account: String?
    var realname: String?
    var user: String?
    var host: String?
    var isBot = false
    var isAway = false
    var id: String { nick }

    var prefix: Character? { prefixes.first }

    var sortRank: Int {
        switch prefix {
        case "~": return 0
        case "&": return 1
        case "@": return 2
        case "%": return 3
        case "+": return 4
        default: return 5
        }
    }
}

/// Messages around a reply's original, fetched with `CHATHISTORY AROUND`
/// because it predates the loaded scrollback.
struct AroundContext: Identifiable {
    var target: String
    var msgid: String
    var lines: [ChatLine] = []
    var isLoading = true
    var failed = false
    var dismissed = false
    var id: String { msgid }
}

/// A conversation: the network's status window, a channel, or a query.
@MainActor @Observable
final class Buffer: Identifiable {
    enum Kind: String, Sendable, Codable { case status, channel, query }

    let id = UUID()
    private(set) var name: String
    var kind: Kind
    var lines: [ChatLine] = []
    var topic: String?
    var topicSetBy: String?
    var members: [Member] = []
    var membersLoaded = false
    var unreadCount = 0
    var hasMention = false
    var isJoined = false
    var loadedHistory = false
    /// `draft/read-marker`: lines at or before this are read on every device.
    var readMarker: Date?
    var isLoadingHistory = false
    var historyExhausted = false
    /// `+typing`: nick → last "active".
    var typing: [String: Date] = [:]
    /// Set by the session: lines from ignored senders stay stored but hidden.
    var isHidden: (ChatLine) -> Bool = { _ in false }
    /// MONITOR presence of a query's peer; `nil` while unknown.
    var peerOnline: Bool?
    var peerAway = false
    /// Reaction/typing TAGMSGs and lines already applied, by msgid.
    private var seenMsgIDs: Set<String> = []

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// A query follows its peer through a nick change.
    func rename(_ newName: String) { name = newName }

    func markProcessed(_ msgid: String) -> Bool {
        seenMsgIDs.insert(msgid).inserted
    }

    func restore(_ snapshot: HistoryStore.BufferSnapshot) {
        lines = snapshot.lines.filter { !$0.isPending }
        for case let mid? in lines.map(\.msgid) { seenMsgIDs.insert(mid) }
        topic = snapshot.topic
        readMarker = snapshot.readMarker
        historyExhausted = snapshot.historyExhausted
        loadedHistory = !lines.isEmpty
        recomputeUnread()
    }

    func resetHistory() {
        lines.removeAll()
        seenMsgIDs.removeAll()
        loadedHistory = false
        historyExhausted = false
        unreadCount = 0
    }

    /// Newest server-originated timestamp, the `CHATHISTORY AFTER` boundary.
    var newestMessageTimestamp: Date? {
        lines.lazy
            .filter { !$0.isPending && ($0.msgid != nil || $0.kind.countsAsUnread || $0.direction?.isPresence == true) }
            .map(\.timestamp)
            .max()
    }

    var sortedMembers: [Member] {
        members.sorted {
            $0.sortRank != $1.sortRank
                ? $0.sortRank < $1.sortRank
                : $0.nick.lowercased() < $1.nick.lowercased()
        }
    }

    func append(_ line: ChatLine, markUnread: Bool) {
        if let mid = line.msgid, !markProcessed(mid) { return }
        if line.msgid == nil, line.isHistorical,
           lines.contains(where: { $0.msgid == nil && $0.timestamp == line.timestamp
                                   && $0.kind == line.kind && $0.sender == line.sender
                                   && $0.text == line.text && $0.direction == line.direction }) {
            return
        }
        if line.isHistorical {
            let index = lines.firstIndex { $0.timestamp > line.timestamp } ?? lines.endIndex
            lines.insert(line, at: index)
        } else {
            lines.append(line)
        }
        if markUnread && !line.isHistorical {
            if let marker = readMarker, line.timestamp <= marker { return }
            unreadCount += 1
        }
    }

    /// Turns our pending (graphite) line into the confirmed one the server
    /// echoed. Matched by label first, else by the oldest pending line with the
    /// same text. Returns false when nothing was pending for it.
    func confirmPending(with echo: ChatLine) -> Bool {
        let index = echo.label.flatMap { label in lines.lastIndex { $0.isPending && $0.label == label } }
            ?? lines.firstIndex { $0.isPending && $0.text == echo.text && $0.kind == echo.kind }
        guard let index else { return false }
        if let mid = echo.msgid, !markProcessed(mid) { return true }
        var confirmed = echo
        confirmed.isPending = false
        // Keep the pending line's identity so the view animates pencil → ink
        // on the same row instead of swapping rows.
        lines[index] = ChatLine(id: lines[index].id, timestamp: confirmed.timestamp, sender: confirmed.sender,
                                text: confirmed.text, kind: confirmed.kind, isSelf: true,
                                account: confirmed.account, msgid: confirmed.msgid,
                                replyTo: confirmed.replyTo ?? lines[index].replyTo,
                                sourceUser: confirmed.sourceUser, sourceHost: confirmed.sourceHost)
        return true
    }

    /// A pending line the server refused or never echoed.
    func failPending(label: String) {
        guard let index = lines.lastIndex(where: { $0.isPending && $0.label == label }) else { return }
        lines[index].kind = .error
        lines[index].isPending = false
    }

    func recomputeUnread() {
        guard let marker = readMarker else { return }
        let count = lines.filter {
            !$0.isSelf && $0.kind.countsAsUnread && $0.timestamp > marker && !isHidden($0)
        }.count
        unreadCount = count
        if count == 0 { hasMention = false }
    }

    /// The read marker as it was when you opened this conversation: the ⁂
    /// stays where you left off for the whole visit, even as the live marker
    /// moves on with what you're reading now. `nil` when not being viewed.
    var entryMarker: Date?

    var firstUnreadID: UUID? { firstUnread(after: readMarker) }

    /// Where the ⁂ goes while you're in this conversation.
    var sceneBreakID: UUID? { firstUnread(after: entryMarker ?? readMarker) }

    func firstUnread(after marker: Date?) -> UUID? {
        guard let marker else { return nil }
        return lines.first {
            !$0.isSelf && $0.kind.countsAsUnread && $0.timestamp > marker && !isHidden($0)
        }?.id
    }

    func addReaction(_ emoji: String, toMsgID msgid: String, from nick: String) {
        guard let index = lines.firstIndex(where: { $0.msgid == msgid }) else { return }
        lines[index].reactions[emoji, default: []].insert(nick)
    }

    func removeReaction(_ emoji: String, fromMsgID msgid: String, by nick: String) {
        guard let index = lines.firstIndex(where: { $0.msgid == msgid }) else { return }
        lines[index].reactions[emoji]?.remove(nick)
        if lines[index].reactions[emoji]?.isEmpty == true { lines[index].reactions[emoji] = nil }
    }

    func hasReaction(_ emoji: String, onMsgID msgid: String, from nick: String) -> Bool {
        lines.first { $0.msgid == msgid }?.reactions[emoji]?.contains(nick) ?? false
    }

    func updateMember(_ nick: String, equals: (String, String) -> Bool, _ change: (inout Member) -> Void) {
        if let i = members.firstIndex(where: { equals($0.nick, nick) }) { change(&members[i]) }
    }

    @discardableResult
    func redact(msgid: String, by nick: String?, reason: String?) -> Bool {
        guard let index = lines.firstIndex(where: { $0.msgid == msgid }) else { return false }
        lines[index].redacted = true
        lines[index].redactedBy = nick
        lines[index].redactionReason = reason
        return true
    }

    func currentlyTyping(asOf now: Date) -> [String] {
        typing.filter { now.timeIntervalSince($0.value) < 6 }
            .keys.sorted { $0.lowercased() < $1.lowercased() }
    }

    func line(withMsgID msgid: String) -> ChatLine? {
        lines.last { $0.msgid == msgid }
    }
}

/// A network advertised by a soju bouncer (`soju.im/bouncer-networks`).
struct BouncerNetwork: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var state: String?
    var host: String?
    var nickname: String?
    var attributes: [String: String]
}

/// A nick on the MONITOR list (the sidebar's people).
struct Buddy: Identifiable, Sendable, Equatable {
    var nick: String
    var online: Bool?
    var away = false
    var id: String { nick.lowercased() }
}

/// A WHOIS answer, collected across its numerics and shown as a card.
struct WhoisCard: Identifiable, Sendable {
    var nick: String
    var user: String?
    var host: String?
    var realname: String?
    var server: String?
    var account: String?
    var channels: [String] = []
    var idle: TimeInterval?
    var signon: Date?
    var away: String?
    var isOperator = false
    var isSecure = false
    var isBot = false
    var certFP: String?
    var extra: [String] = []
    var id: String { nick }
}
