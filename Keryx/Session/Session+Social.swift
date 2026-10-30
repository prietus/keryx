import Foundation
import KeryxProtocol

extension Session {
    // MARK: - Sending messages

    var echoes: Bool { enabledCaps.contains(CapabilityName.echoMessage) }
    var networkAllowsReactions: Bool {
        enabledCaps.contains(CapabilityName.messageTags) && isupport.allowsClientTag("draft/react")
    }
    var networkAllowsRedaction: Bool { enabledCaps.contains(CapabilityName.messageRedaction) }

    /// Sends a message the way the reader would expect: one line per line,
    /// long lines split at word boundaries, and a `draft/multiline` batch
    /// when the server can keep them together. Our copy appears at once in
    /// graphite (pending) and turns to ink when the server echoes it.
    func sendMessage(_ body: String, to buffer: Buffer, replyTo: String? = nil, action: Bool = false) {
        guard buffer.kind != .status else {
            note(String(localized: "The status window isn’t a conversation. Try /join #channel."), in: buffer, kind: .error)
            return
        }
        var tags: [String: String] = [:]
        if let replyTo, isupport.allowsClientTag("draft/reply") || isupport.allowsClientTag("reply") {
            tags["+reply"] = replyTo
            tags["+draft/reply"] = replyTo
        }
        let limit = maxPayloadBytes(for: buffer.name, action: action)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kind: ChatLine.Kind = action ? .action : .message
        let wrap: (String) -> String = { action ? "\u{01}ACTION \($0)\u{01}" : $0 }

        if enabledCaps.contains(CapabilityName.multiline), !action,
           lines.count > 1 || body.utf8.count > limit {
            multilineCounter += 1
            let ref = "ml\(multilineCounter)"
            var open = IRCMessage(tags: tags, command: "BATCH", parameters: ["+\(ref)", CapabilityName.multiline, buffer.name])
            let label = enabledCaps.contains(CapabilityName.labeledResponse) ? nextLabel() : nil
            if let label { open.tags["label"] = label }
            send(open)
            for line in lines {
                for (index, chunk) in Self.chunk(line, maxBytes: limit).enumerated() {
                    var tags = ["batch": ref]
                    if index > 0 { tags["draft/multiline-concat"] = "" }
                    send(IRCMessage(tags: tags, command: "PRIVMSG", parameters: [buffer.name, chunk]))
                }
            }
            send(.batchClose(ref))
            recordOwnLine(body, kind: kind, in: buffer, replyTo: replyTo, label: label)
            return
        }
        for line in lines {
            for chunk in Self.chunk(line, maxBytes: limit) {
                var message = IRCMessage(tags: tags, command: "PRIVMSG", parameters: [buffer.name, wrap(chunk)])
                let label = echoes && enabledCaps.contains(CapabilityName.labeledResponse) ? nextLabel() : nil
                if let label { message.tags["label"] = label }
                send(message)
                recordOwnLine(chunk, kind: kind, in: buffer, replyTo: replyTo, label: label)
            }
        }
        stopTyping(buffer)
    }

    private func recordOwnLine(_ text: String, kind: ChatLine.Kind, in buffer: Buffer, replyTo: String?, label: String?) {
        let line = ChatLine(timestamp: Date(), sender: currentNick, text: text, kind: kind, isSelf: true,
                            replyTo: replyTo, isPending: echoes, label: label)
        buffer.append(line, markUnread: false)
        if !echoes { onIndexLine?(line, buffer, self) }
        // A line the server never echoes (dropped, or a server that skips
        // echoes for some targets) shouldn't stay in pencil forever.
        guard echoes else { return }
        let id = line.id
        Task { [weak buffer] in
            try? await Task.sleep(for: .seconds(20))
            guard let buffer, let i = buffer.lines.firstIndex(where: { $0.id == id && $0.isPending }) else { return }
            buffer.lines[i].isPending = false
        }
    }

    /// Room left for text in a PRIVMSG after the prefix the server adds.
    func maxPayloadBytes(for target: String, action: Bool) -> Int {
        let prefix = 1 + currentNick.utf8.count + 1 + 10 + 1 + 63 + 1
        let fixed = "PRIVMSG ".utf8.count + target.utf8.count + 2 + 2 + (action ? 9 : 0)
        return max(64, 512 - prefix - fixed)
    }

    /// Splits `text` into pieces of at most `maxBytes` UTF-8 bytes, at a space
    /// when possible, never inside a character.
    static func chunk(_ text: String, maxBytes: Int) -> [String] {
        guard text.utf8.count > maxBytes else { return [text] }
        let chars = Array(text)
        var pieces: [String] = []
        var start = 0
        while start < chars.count {
            var bytes = 0
            var end = start
            var lastSpace = -1
            while end < chars.count {
                let size = String(chars[end]).utf8.count
                if bytes + size > maxBytes { break }
                if chars[end] == " " { lastSpace = end }
                bytes += size
                end += 1
            }
            if end == chars.count {
                pieces.append(String(chars[start..<end]))
                break
            }
            if lastSpace > start {
                pieces.append(String(chars[start..<lastSpace]))
                start = lastSpace + 1
            } else {
                pieces.append(String(chars[start..<max(end, start + 1)]))
                start = max(end, start + 1)
            }
        }
        return pieces
    }

    // MARK: - Joining & conversations

    func join(_ channel: String, key: String? = nil) {
        sendLabeled(.join(channel, key: key), describedAs: "JOIN \(channel)")
    }

    func part(_ buffer: Buffer, reason: String? = nil) {
        if buffer.kind == .channel, buffer.isJoined { send(.part(buffer.name, reason: reason)) }
        removeBuffer(buffer)
    }

    @discardableResult
    func openQuery(_ nick: String) -> Buffer {
        let query = buffer(named: nick, kind: .query, createIfMissing: true)!
        if !query.loadedHistory { requestHistory(for: query) }
        return query
    }

    /// Fetches a channel's roster on first view (no-implicit-names), with one
    /// WHO (WHOX when available) for away, bot and account state.
    func loadMembersIfNeeded(_ buffer: Buffer) {
        guard buffer.kind == .channel, buffer.isJoined, !buffer.membersLoaded, status == .connected else { return }
        buffer.membersLoaded = true
        let implicit = !enabledCaps.contains(CapabilityName.noImplicitNames)
            && !enabledCaps.contains(CapabilityName.sojuNoImplicitNames)
        if !implicit || buffer.members.isEmpty { send(.names(buffer.name)) }
        if isupport.tokens["WHOX"] != nil {
            send(IRCMessage(command: "WHO", parameters: [buffer.name, "%tcuhnfar,\(Self.whoxToken)"]))
        } else {
            send(IRCMessage(command: "WHO", parameters: [buffer.name]))
        }
    }

    // MARK: - Typing (+typing)

    func notifyTyping(in buffer: Buffer, hasText: Bool, enabled: Bool) {
        guard enabled, buffer.kind != .status, status == .connected,
              enabledCaps.contains(CapabilityName.messageTags), isupport.allowsClientTag("typing") else { return }
        let key = fold(buffer.name)
        if hasText {
            if let last = typingSent[key], Date().timeIntervalSince(last) < 3 { return }
            typingSent[key] = Date()
            send(.tagmsg(buffer.name, tags: ["+typing": "active"]))
        } else {
            stopTyping(buffer)
        }
    }

    func stopTyping(_ buffer: Buffer) {
        let key = fold(buffer.name)
        guard typingSent.removeValue(forKey: key) != nil, enabledCaps.contains(CapabilityName.messageTags) else { return }
        send(.tagmsg(buffer.name, tags: ["+typing": "done"]))
    }

    // MARK: - Reactions & redaction

    func toggleReaction(_ emoji: String, to line: ChatLine, in buffer: Buffer) {
        guard let msgid = line.msgid, enabledCaps.contains(CapabilityName.messageTags) else { return }
        let mine = buffer.hasReaction(emoji, onMsgID: msgid, from: currentNick)
        send(.tagmsg(buffer.name, tags: ["+reply": msgid, "+draft/reply": msgid,
                                         mine ? "+draft/unreact" : "+draft/react": emoji]))
        if mine { buffer.removeReaction(emoji, fromMsgID: msgid, by: currentNick) }
        else { buffer.addReaction(emoji, toMsgID: msgid, from: currentNick) }
    }

    func redact(_ line: ChatLine, in buffer: Buffer, reason: String? = nil) {
        guard let msgid = line.msgid, networkAllowsRedaction else { return }
        var params = [buffer.name, msgid]
        if let reason, !reason.isEmpty { params.append(reason) }
        send(IRCMessage(command: "REDACT", parameters: params))
        buffer.redact(msgid: msgid, by: currentNick, reason: reason)
    }

    // MARK: - Ignore & dim

    func isIgnored(nick: String, user: String?, host: String?, account: String?) -> Bool {
        !state.ignores.isEmpty && state.ignores.contains {
            $0.matches(nick: nick, user: user, host: host, account: account, caseMapping: isupport.caseMapping)
        }
    }

    func isIgnored(_ line: ChatLine) -> Bool {
        guard !state.ignores.isEmpty, !line.isSelf, let nick = line.subjectNick else { return false }
        return isIgnored(nick: nick, user: line.sourceUser, host: line.sourceHost, account: line.account)
    }

    func isDimmed(_ nick: String) -> Bool { state.dimmed.contains { equal($0, nick) } }

    @discardableResult
    func ignore(_ mask: IgnoreMask) -> Bool {
        guard ignoreIndex(of: mask) == nil else { return false }
        state.ignores.append(mask)
        ignoresChanged()
        if let nick = mask.plainNick { pushMetadataFlag(CapabilityName.sojuBlocked, nick, true) }
        return true
    }

    @discardableResult
    func unignore(_ mask: IgnoreMask) -> Bool {
        guard let index = ignoreIndex(of: mask) else { return false }
        let removed = state.ignores.remove(at: index)
        ignoresChanged()
        if let nick = removed.plainNick { pushMetadataFlag(CapabilityName.sojuBlocked, nick, false) }
        return true
    }

    func setDimmed(_ dimmed: Bool, _ nick: String) {
        state.dimmed.removeAll { equal($0, nick) }
        if dimmed { state.dimmed.append(nick) }
        saveState()
    }

    func plainIgnore(for nick: String) -> IgnoreMask? {
        state.ignores.first { $0.plainNick.map { equal($0, nick) } ?? false }
    }

    private func ignoreIndex(of mask: IgnoreMask) -> Int? {
        let folded = fold(mask.pattern)
        return state.ignores.firstIndex { fold($0.pattern) == folded }
    }

    private func ignoresChanged() {
        saveState()
        for buffer in buffers {
            buffer.typing = buffer.typing.filter { !isIgnored(nick: $0.key, user: nil, host: nil, account: nil) }
            buffer.recomputeUnread()
        }
    }

    func saveState() { state.save(config.id) }

    // MARK: - Spelling language (/lang)

    /// The conversation's spelling language: a code, "off", or `nil` to let
    /// macOS detect it.
    func spellingLanguage(for name: String) -> String? {
        state.languages?[name.lowercased()]
    }

    func setSpellingLanguage(_ language: String?, for name: String) {
        var languages = state.languages ?? [:]
        languages[name.lowercased()] = language
        state.languages = languages.isEmpty ? nil : languages
        saveState()
    }

    // MARK: - Mute, pin, quiet presence

    func isMuted(_ name: String) -> Bool { state.muted.contains(name.lowercased()) }
    func isPinned(_ name: String) -> Bool { state.pinned.contains(name.lowercased()) }
    func isPresenceQuiet(_ name: String) -> Bool { state.quietPresence.contains(name.lowercased()) }

    func setMuted(_ muted: Bool, for name: String) {
        setLocalFlag(CapabilityName.sojuMuted, name, muted)
        pushMetadataFlag(CapabilityName.sojuMuted, name, muted)
    }

    func setPinned(_ pinned: Bool, for name: String) {
        setLocalFlag(CapabilityName.sojuPinned, name, pinned)
        pushMetadataFlag(CapabilityName.sojuPinned, name, pinned)
    }

    func setPresenceQuiet(_ quiet: Bool, for name: String) {
        if quiet { state.quietPresence.insert(name.lowercased()) } else { state.quietPresence.remove(name.lowercased()) }
        saveState()
    }

    // MARK: - soju metadata sync (blocked / muted / pinned)

    static let syncedMetadataKeys = [CapabilityName.sojuBlocked, CapabilityName.sojuMuted, CapabilityName.sojuPinned]
    static let userMetadataKeys = ["avatar", "display-name", "pronouns", "color", "status", "homepage"]
    static let profileKeys = ["display-name", "pronouns", "avatar", "color", "homepage", "status"]

    var isSoju: Bool { negotiator.available.contains { $0.name == CapabilityName.bouncerNetworks } }
    var supportsProfile: Bool { enabledCaps.contains(CapabilityName.metadata) && !isSoju }
    private var canSyncMetadata: Bool {
        enabledCaps.contains(CapabilityName.metadata) && config.isExplicitlyBound && isSoju
    }

    func subscribeMetadata() {
        var keys: [String] = []
        if canSyncMetadata {
            metadataSyncing = Set(Self.syncedMetadataKeys)
            keys += Self.syncedMetadataKeys
        }
        if supportsProfile { keys += Self.userMetadataKeys }
        if !keys.isEmpty { send(IRCMessage(command: "METADATA", parameters: ["*", "SUB"] + keys)) }
    }

    private func normalized(_ target: String, for key: String) -> String {
        key == CapabilityName.sojuBlocked ? fold(target) : target.lowercased()
    }

    private func localFlags(_ key: String) -> [String: String] {
        switch key {
        case CapabilityName.sojuBlocked:
            var out: [String: String] = [:]
            for rule in state.ignores { if let nick = rule.plainNick { out[fold(nick)] = nick } }
            return out
        case CapabilityName.sojuMuted:
            return Dictionary(uniqueKeysWithValues: state.muted.map { ($0, $0) })
        default:
            return Dictionary(uniqueKeysWithValues: state.pinned.map { ($0, $0) })
        }
    }

    private func setLocalFlag(_ key: String, _ target: String, _ on: Bool) {
        switch key {
        case CapabilityName.sojuBlocked:
            if on {
                if plainIgnore(for: target) == nil, let mask = IgnoreMask(parsing: target) {
                    state.ignores.append(mask)
                    ignoresChanged()
                }
            } else if let rule = plainIgnore(for: target), let i = ignoreIndex(of: rule) {
                state.ignores.remove(at: i)
                ignoresChanged()
            }
        case CapabilityName.sojuMuted:
            if on { state.muted.insert(target.lowercased()) } else { state.muted.remove(target.lowercased()) }
            saveState()
        default:
            if on { state.pinned.insert(target.lowercased()) } else { state.pinned.remove(target.lowercased()) }
            saveState()
        }
    }

    private func recordSynced(_ key: String, _ target: String, _ on: Bool) {
        let name = normalized(target, for: key)
        if on { state.synced[key, default: []].insert(name) } else { state.synced[key]?.remove(name) }
        saveState()
    }

    private func pushMetadataFlag(_ key: String, _ target: String, _ on: Bool) {
        guard metadataActive.contains(key) else { return }
        send(IRCMessage(command: "METADATA", parameters: [target, "SET", key, on ? "1" : "0"]))
        recordSynced(key, target, on)
    }

    func handleMetadata(target: String, key: String, value: String?) {
        let key = key.lowercased()
        if Self.userMetadataKeys.contains(key) {
            guard target != "*", !isupport.isChannel(target) else { return }
            if let value, !value.isEmpty { userMetadata[fold(target), default: [:]][key] = value }
            else { userMetadata[fold(target)]?[key] = nil }
            return
        }
        guard Self.syncedMetadataKeys.contains(key), target != "*",
              key != CapabilityName.sojuBlocked || !isupport.isChannel(target) else { return }
        let on = value == "1"
        if metadataSyncing.contains(key) {
            if on { metadataServerState[key, default: [:]][normalized(target, for: key)] = target }
        } else if metadataActive.contains(key) {
            setLocalFlag(key, target, on)
            recordSynced(key, target, on)
        }
    }

    /// Three-way merge of soju's state, ours, and the state at the last sync,
    /// so neither side's changes made while apart are lost or resurrected.
    func finishMetadataSync(_ key: String) {
        metadataSyncing.remove(key)
        let server = metadataServerState.removeValue(forKey: key) ?? [:]
        let local = localFlags(key)
        let synced = state.synced[key] ?? []
        var toServer: [(String, Bool)] = []
        for (name, target) in server where local[name] == nil {
            if synced.contains(name) { toServer.append((target, false)) } else { setLocalFlag(key, target, true) }
        }
        for (name, target) in local where server[name] == nil {
            if synced.contains(name) { setLocalFlag(key, target, false) } else { toServer.append((target, true)) }
        }
        metadataActive.insert(key)
        for (target, on) in toServer {
            send(IRCMessage(command: "METADATA", parameters: [target, "SET", key, on ? "1" : "0"]))
        }
        state.synced[key] = Set(localFlags(key).keys)
        saveState()
    }

    // MARK: - Profile (draft/metadata-2)

    func metadata(for nick: String) -> [String: String] { userMetadata[fold(nick)] ?? [:] }

    func avatarURL(for nick: String) -> URL? {
        guard let raw = metadata(for: nick)["avatar"], let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    func setProfile(_ newProfile: [String: String]) {
        let cleaned = newProfile.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.filter { Self.profileKeys.contains($0.key) }
        let previous = state.profile
        state.profile = cleaned
        saveState()
        guard status == .connected, supportsProfile else { return }
        for key in Self.profileKeys where cleaned[key] != previous[key] { publishProfileKey(key, cleaned[key]) }
    }

    func publishProfile() {
        guard supportsProfile else { return }
        for key in Self.profileKeys {
            if let value = state.profile[key] { publishProfileKey(key, value) }
            else if state.publishedProfileKeys.contains(key) { publishProfileKey(key, nil) }
        }
    }

    private func publishProfileKey(_ key: String, _ value: String?) {
        send(IRCMessage(command: "METADATA", parameters: ["*", "SET", key] + (value.map { [$0] } ?? [])))
        if let value {
            state.publishedProfileKeys.insert(key)
            userMetadata[fold(currentNick), default: [:]][key] = value
        } else {
            state.publishedProfileKeys.remove(key)
            userMetadata[fold(currentNick)]?[key] = nil
        }
        saveState()
    }

    // MARK: - MONITOR: buddies and query peers

    var supportsMonitor: Bool { isupport.monitorLimit != nil }

    func isBuddy(_ nick: String) -> Bool { buddies.contains { equal($0.nick, nick) } }

    func addBuddy(_ nick: String) {
        guard !isBuddy(nick), !isupport.isChannel(nick) else { return }
        buddies.append(Buddy(nick: nick))
        buddies.sort { $0.nick.lowercased() < $1.nick.lowercased() }
        state.buddies = buddies.map(\.nick)
        saveState()
        monitor([nick])
    }

    func removeBuddy(_ nick: String) {
        buddies.removeAll { equal($0.nick, nick) }
        state.buddies = buddies.map(\.nick)
        saveState()
        if buffer(named: nick, kind: .query, createIfMissing: false) == nil { unmonitor(nick) }
    }

    /// MONITOR lists don't survive a reconnect: re-arm them once registered.
    func startMonitoring() {
        guard !monitorStarted, supportsMonitor else { return }
        monitorStarted = true
        monitor(buffers.filter { $0.kind == .query }.map(\.name) + buddies.map(\.nick))
    }

    func monitor(_ nicks: [String]) {
        guard monitorStarted, let limit = isupport.monitorLimit else { return }
        var batch: [String] = []
        var length = 0
        for nick in nicks {
            let key = fold(nick)
            guard !monitored.contains(key), !isupport.isChannel(nick) else { continue }
            if let limit, monitored.count >= limit { break }
            if length + nick.count + 1 > 400 {
                send(IRCMessage(command: "MONITOR", parameters: ["+", batch.joined(separator: ",")]))
                batch = []
                length = 0
            }
            monitored.insert(key)
            batch.append(nick)
            length += nick.count + 1
        }
        if !batch.isEmpty { send(IRCMessage(command: "MONITOR", parameters: ["+", batch.joined(separator: ",")])) }
    }

    func unmonitor(_ nick: String) {
        guard monitorStarted, monitored.remove(fold(nick)) != nil else { return }
        send(IRCMessage(command: "MONITOR", parameters: ["-", nick]))
    }

    func setPresence(_ nick: String, online: Bool) {
        if let query = buffer(named: nick, kind: .query, createIfMissing: false) {
            query.peerOnline = online
            if !online { query.peerAway = false }
        }
        guard let i = buddies.firstIndex(where: { equal($0.nick, nick) }) else { return }
        let was = buddies[i].online
        buddies[i].online = online
        if !online { buddies[i].away = false }
        if was == false, online {
            let query = buffer(named: nick, kind: .query, createIfMissing: false) ?? statusBuffer
            onNotifiableEvent?(NotifiableEvent(kind: .buddyOnline, sessionID: id, bufferID: query.id,
                                               title: String(localized: "\(buddies[i].nick) is online"), sender: buddies[i].nick,
                                               text: String(localized: "On \(displayName).")))
        }
    }

    // MARK: - Uploads

    /// The server's own file host (`draft/FILEHOST` / `soju.im/FILEHOST`).
    var fileHost: FileHostTarget? {
        guard status == .connected, let url = isupport.fileHost(allowInsecure: !config.useTLS) else { return nil }
        var target = FileHostTarget(url: url)
        if config.saslMode == .plain, let password = config.saslPassword {
            // The `@client` and `/network` suffixes only mean something to the
            // IRC side of soju; the HTTP upload wants the bare account.
            let account = config.saslAccount
            target.basicUser = String(account.prefix { $0 != "@" && $0 != "/" })
            target.basicPassword = password
        }
        return target
    }

    /// Where an upload from this network would go, given the user's settings.
    func uploadDestination(_ prefs: Preferences) -> UploadDestination? {
        let custom = CustomUploader(prefs)
        if let host = fileHost, prefs.preferServerFileHost || custom == nil { return .server(host) }
        return custom.map { .custom($0) }
    }

    // MARK: - WHOIS

    func requestWhois(_ nick: String) {
        pendingWhois = WhoisCard(nick: nick)
        send(IRCMessage(command: "WHOIS", parameters: [nick, nick]))
    }
}
