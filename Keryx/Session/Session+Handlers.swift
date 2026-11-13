import Foundation
import KeryxProtocol

extension Session {
    // MARK: - Messages

    func handlePrivmsg(_ message: IRCMessage, isNotice: Bool) {
        guard let target = message.first, let text = message.trailing else { return }
        if let ref = message.tags["batch"], openBatches[ref]?.type == CapabilityName.multiline {
            accumulateMultiline(ref, message)
            return
        }
        // Server notices (no user@host) belong to the status window.
        if let source = message.source, !source.isUser, !isupport.isChannel(target) {
            if text.hasPrefix("\u{01}") { return }
            statusBuffer.append(ChatLine(timestamp: timestamp(from: message), sender: source.name, text: text,
                                         kind: isNotice ? .notice : .message, msgid: message.tags["msgid"],
                                         isHistorical: batchInfo(for: message)?.isHistory ?? false),
                                markUnread: false)
            return
        }
        // Services and the bouncer talk to us before registration ends.
        if message.source == nil || target == "*" {
            addStatus(text, kind: isNotice ? .notice : .event)
            return
        }
        let info = batchInfo(for: message)
        if let ref = message.tags["batch"], info?.isHistory == true {
            openBatches[ref]?.messageCount += 1
        }

        var kind: ChatLine.Kind = isNotice ? .notice : .message
        var body = text
        if text.hasPrefix("\u{01}ACTION "), text.hasSuffix("\u{01}") {
            body = String(text.dropFirst(8).dropLast())
            kind = .action
        } else if text.hasPrefix("\u{01}") {
            guard info?.isHistory != true else { return }
            if isNotice { showCTCPReply(text, from: message.source) } else { answerCTCP(text, from: message.source) }
            return
        }
        deliver(body, kind: kind, to: target, source: message.source, tags: message.tags,
                historical: info?.isHistory ?? false,
                aroundContext: info?.isAroundContext ?? false)
    }

    /// Files one finished message (single line or a whole multiline batch).
    func deliver(_ body: String, kind: ChatLine.Kind, to target: String, source: IRCSource?,
                 tags: [String: String], historical: Bool, aroundContext isAround: Bool) {
        let sender = source?.nick ?? "*"
        let isSelf = equal(sender, currentNick)
        let ignored = !isSelf && isIgnored(nick: sender, user: source?.user, host: source?.host,
                                           account: tags["account"])
        var place = self.target(for: target, from: sender, isSelf: isSelf)
        // A bot or service answering you privately about a channel: show it
        // in that channel, as a whisper, rather than in a query of its own.
        var whisper = false
        if place.kind == .query, !isSelf, let context = tags["+draft/channel-context"],
           isupport.isChannel(context), self.buffer(named: context, kind: .channel, createIfMissing: false) != nil {
            place = (context, .channel)
            whisper = true
        }
        guard let buffer = buffer(named: place.name, kind: place.kind,
                                  createIfMissing: !(ignored && place.kind == .query)) else { return }
        let mentions = !isSelf && !ignored && (whisper || isHighlight(body))
        var line = ChatLine(timestamp: tags["time"].flatMap(Self.timeFormatter.date(from:)) ?? Date(),
                            sender: sender, text: body, kind: kind, isSelf: isSelf,
                            account: tags["account"], msgid: tags["msgid"], replyTo: replyRef(tags),
                            isHistorical: historical, sourceUser: source?.user, sourceHost: source?.host,
                            label: tags["label"], mentionsMe: mentions)
        if whisper { line.whisper = true }
        if isAround {
            aroundContext?.lines.append(line)
            return
        }
        // Our echo turns the graphite draft into ink.
        if isSelf, !historical, buffer.confirmPending(with: line) {
            onIndexLine?(line, buffer, self)
            return
        }
        let before = buffer.lines.count
        let viewing = isViewing(buffer)
        buffer.append(line, markUnread: !isSelf && !ignored && !viewing)
        guard buffer.lines.count > before else { return }
        onIndexLine?(line, buffer, self)
        if historical { return }
        buffer.typing[sender] = nil
        if viewing { markReadSoon(buffer) } else if mentions { buffer.hasMention = true }
        if !isSelf, !ignored, kind != .notice {
            if buffer.kind == .query {
                emitNotification(.directMessage, buffer: buffer, sender: sender, text: body)
            } else if mentions {
                emitNotification(.mention, buffer: buffer, sender: sender, text: body)
            }
        }
    }

    /// The parent msgid: ratified `+reply`, falling back to `+draft/reply`.
    func replyRef(_ tags: [String: String]) -> String? {
        tags["+reply"] ?? tags["+draft/reply"]
    }

    /// Replies to the CTCP queries clients still send: VERSION, PING, TIME,
    /// CLIENTINFO. Everything else is dropped.
    private func answerCTCP(_ text: String, from source: IRCSource?) {
        guard let nick = source?.nick, !isIgnored(nick: nick, user: source?.user, host: source?.host, account: nil)
        else { return }
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{01}"))
        let parts = inner.split(separator: " ", maxSplits: 1).map(String.init)
        let reply: String?
        switch parts.first?.uppercased() {
        case "VERSION": reply = "VERSION \(Self.version)"
        case "PING": reply = "PING \(parts.count > 1 ? parts[1] : "")"
        case "TIME": reply = "TIME \(Date().formatted(.iso8601))"
        case "CLIENTINFO": reply = "CLIENTINFO ACTION CLIENTINFO PING TIME VERSION"
        default: reply = nil
        }
        if let reply { send(.notice(nick, "\u{01}\(reply)\u{01}")) }
        // Like WeeChat: a quiet note that someone asked.
        let what = parts.first?.uppercased() ?? "?"
        addStatus(String(localized: "\(nick) sent you a CTCP \(what)."))
    }

    /// A CTCP reply (a NOTICE wrapped in \u{01}), shown where you asked:
    /// "VERSION from ana: irssi 1.4.5", "PING from ana: 84 ms".
    private func showCTCPReply(_ text: String, from source: IRCSource?) {
        guard let nick = source?.nick else { return }
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{01}"))
        let parts = inner.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts.first?.uppercased() ?? "?"
        var answer = parts.count > 1 ? parts[1] : ""
        if command == "PING", let sent = Double(answer) {
            let ms = Int((Date().timeIntervalSince1970 - sent) * 1000)
            answer = String(localized: "\(ms) ms")
        }
        let place = ctcpPending.removeValue(forKey: fold(nick))
            .flatMap { name in buffers.first { equal($0.name, name) } }
            ?? buffer(named: nick, kind: .query, createIfMissing: false)
            ?? statusBuffer
        note(String(localized: "\(command) from \(nick): \(answer)"), in: place)
    }

    // MARK: - Presence

    func handleJoin(_ message: IRCMessage) {
        guard let channel = message.first, let source = message.source else { return }
        let buffer = buffer(named: channel, kind: .channel, createIfMissing: true)!
        let historical = batchInfo(for: message)?.isHistory ?? false
        if equal(source.nick, currentNick) {
            guard !historical else { return }
            buffer.isJoined = true
            buffer.membersLoaded = false
            requestHistory(for: buffer)
            return
        }
        let account = message.parameter(1).flatMap { $0 == "*" ? nil : $0 } ?? message.tags["account"]
        let realname = message.parameters.count >= 3 ? message.trailing : nil
        if !historical {
            addMember(Member(nick: source.nick, account: account, realname: realname,
                             user: source.user, host: source.host), to: buffer)
        }
        if let ref = message.tags["batch"], openBatches[ref]?.type == "netjoin" {
            if !(openBatches[ref]?.splitNicks.contains(source.nick) ?? true) {
                openBatches[ref]?.splitNicks.append(source.nick)
            }
            openBatches[ref]?.splitBuffers.insert(buffer.id)
            return
        }
        appendDirection(.join(nick: source.nick), to: buffer, message: message, historical: historical)
    }

    func handlePart(_ message: IRCMessage) {
        guard let channel = message.first, let source = message.source,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        if equal(source.nick, currentNick) {
            if !historical { buffer.isJoined = false }
            return
        }
        if !historical { removeMember(source.nick, from: buffer) }
        let reason = message.parameters.count > 1 ? message.trailing : nil
        appendDirection(.part(nick: source.nick, reason: reason), to: buffer, message: message, historical: historical)
    }

    func handleQuit(_ message: IRCMessage) {
        guard let source = message.source else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        let inSplit = message.tags["batch"].flatMap { openBatches[$0]?.type == "netsplit" ? $0 : nil }
        if let ref = inSplit { openBatches[ref]?.splitNicks.append(source.nick) }
        for buffer in buffers where buffer.kind == .channel
            && buffer.members.contains(where: { equal($0.nick, source.nick) }) {
            if !historical { removeMember(source.nick, from: buffer) }
            if let ref = inSplit {
                openBatches[ref]?.splitBuffers.insert(buffer.id)
                continue
            }
            appendDirection(.quit(nick: source.nick, reason: message.trailing), to: buffer,
                            message: message, historical: historical)
        }
        if !historical { setPresence(source.nick, online: false) }
    }

    func handleKick(_ message: IRCMessage) {
        guard let channel = message.first, let victim = message.parameter(1),
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        let by = message.source?.nick ?? "?"
        let reason = message.parameters.count > 2 ? message.trailing : nil
        if !historical {
            if equal(victim, currentNick) { buffer.isJoined = false } else { removeMember(victim, from: buffer) }
        }
        appendDirection(.kick(by: by, nick: victim, reason: reason), to: buffer, message: message,
                        historical: historical, force: true)
    }

    func handleNick(_ message: IRCMessage) {
        guard let source = message.source, let newNick = message.first else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        if !historical {
            if equal(source.nick, currentNick) { currentNick = newNick }
            if let profile = userMetadata.removeValue(forKey: fold(source.nick)) {
                userMetadata[fold(newNick)] = profile
            }
            renameQuery(from: source.nick, to: newNick)
        }
        for buffer in buffers where buffer.kind == .channel {
            guard let idx = buffer.members.firstIndex(where: { equal($0.nick, source.nick) }) else { continue }
            if !historical { buffer.members[idx].nick = newNick }
            appendDirection(.nick(old: source.nick, new: newNick), to: buffer, message: message, historical: historical)
        }
        if let query = buffer(named: newNick, kind: .query, createIfMissing: false) {
            appendDirection(.nick(old: source.nick, new: newNick), to: query, message: message, historical: historical)
        }
    }

    func handleAway(_ message: IRCMessage) {
        guard let source = message.source else { return }
        let away = !message.parameters.isEmpty
        for buffer in buffers where buffer.kind == .channel {
            buffer.updateMember(source.nick, equals: equal) { $0.isAway = away }
        }
        buffer(named: source.nick, kind: .query, createIfMissing: false)?.peerAway = away
        if let i = buddies.firstIndex(where: { equal($0.nick, source.nick) }) { buddies[i].away = away }
    }

    /// account-notify: `:nick ACCOUNT <account|*>`.
    func handleAccount(_ message: IRCMessage) {
        guard let source = message.source, let raw = message.first else { return }
        let account = raw == "*" ? nil : raw
        for buffer in buffers where buffer.kind == .channel {
            buffer.updateMember(source.nick, equals: equal) { $0.account = account }
        }
    }

    /// chghost: `:nick!old@old CHGHOST <user> <host>`, in place of a fake quit/join.
    func handleChghost(_ message: IRCMessage) {
        guard let source = message.source, let user = message.first, let host = message.parameter(1) else { return }
        for buffer in buffers where buffer.kind == .channel {
            buffer.updateMember(source.nick, equals: equal) {
                $0.user = user
                $0.host = host
            }
        }
    }

    func handleSetname(_ message: IRCMessage) {
        guard let source = message.source, let newName = message.trailing else { return }
        for buffer in buffers where buffer.kind == .channel {
            buffer.updateMember(source.nick, equals: equal) { $0.realname = newName }
        }
        if equal(source.nick, currentNick) { addStatus(String(localized: "Your real name is now “\(newName)”.")) }
    }

    func handleTopic(_ message: IRCMessage) {
        guard let channel = message.first,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        let by = message.source?.nick ?? "?"
        if !historical {
            buffer.topic = message.trailing
            buffer.topicSetBy = by
        }
        appendDirection(.topic(by: by, text: message.trailing ?? ""), to: buffer, message: message,
                        historical: historical, force: true)
    }

    /// Channel modes: records the change and keeps member prefixes current
    /// (`+o nick` etc.), walking parameters per `CHANMODES` / `PREFIX`.
    func handleMode(_ message: IRCMessage) {
        guard let target = message.first, isupport.isChannel(target),
              let buffer = buffer(named: target, kind: .channel, createIfMissing: false) else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        let modeString = message.parameter(1) ?? ""
        var params = Array(message.parameters.dropFirst(2))
        if !historical {
            let prefixModes = Dictionary(isupport.prefixes.map { ($0.mode, $0.symbol) }) { a, _ in a }
            let order = isupport.prefixes.map(\.symbol)
            let chanModes = (isupport.tokens["CHANMODES"] ?? "beI,k,l,imnpst").split(separator: ",",
                                                                                   omittingEmptySubsequences: false)
            let alwaysParam = Set((chanModes.first ?? "") + (chanModes.count > 1 ? chanModes[1] : ""))
            let paramOnSet = Set(chanModes.count > 2 ? chanModes[2] : "")
            var adding = true
            for char in modeString {
                switch char {
                case "+": adding = true
                case "-": adding = false
                default:
                    if let symbol = prefixModes[char] {
                        guard !params.isEmpty else { continue }
                        let nick = params.removeFirst()
                        buffer.updateMember(nick, equals: equal) { member in
                            var set = Set(member.prefixes)
                            if adding { set.insert(symbol) } else { set.remove(symbol) }
                            member.prefixes = String(order.filter { set.contains($0) })
                        }
                    } else if alwaysParam.contains(char) || (adding && paramOnSet.contains(char)) {
                        if !params.isEmpty { params.removeFirst() }
                    }
                }
            }
        }
        let modes = message.parameters.dropFirst().joined(separator: " ")
        appendDirection(.mode(by: message.source?.nick ?? "?", modes: modes), to: buffer, message: message,
                        historical: historical, force: true)
    }

    /// Appends a stage direction. Presence churn from ignored people is dropped.
    func appendDirection(_ direction: Direction, to buffer: Buffer, message: IRCMessage,
                         historical: Bool, force: Bool = false) {
        if !force, let nick = direction.subject,
           isIgnored(nick: nick, user: message.source?.user, host: message.source?.host, account: nil) { return }
        buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil, text: "", kind: .event,
                               msgid: message.tags["msgid"], direction: direction, isHistorical: historical,
                               sourceUser: message.source?.user, sourceHost: message.source?.host),
                      markUnread: false)
    }

    // MARK: - Rosters

    func handleNamesReply(_ message: IRCMessage) {
        guard let channel = message.parameter(2), let names = message.trailing,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: true) else { return }
        let symbols = isupport.prefixSymbols
        for entry in names.split(separator: " ") {
            var token = Substring(entry)
            var prefixes = ""
            while let first = token.first, symbols.contains(first) {
                prefixes.append(first)
                token = token.dropFirst()
            }
            let source = IRCSource(parsing: token)
            guard !source.nick.isEmpty else { continue }
            addMember(Member(nick: source.nick, prefixes: prefixes, user: source.user, host: source.host),
                      to: buffer, replacePrefix: true)
        }
    }

    func handleWhoReply(_ message: IRCMessage) {
        guard let channel = message.parameter(1), let nick = message.parameter(5),
              let flags = message.parameter(6),
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        let realname = message.trailing?.split(separator: " ", maxSplits: 1).last.map(String.init)
        applyWho(flags, nick: nick, in: buffer, account: nil, user: message.parameter(2),
                 host: message.parameter(3), realname: realname)
    }

    func handleWhoxReply(_ message: IRCMessage) {
        guard message.parameter(1) == Self.whoxToken,
              let channel = message.parameter(2), let nick = message.parameter(5),
              let flags = message.parameter(6),
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        let account = message.parameter(7).flatMap { $0 == "0" ? nil : $0 }
        applyWho(flags, nick: nick, in: buffer, account: account, user: message.parameter(3),
                 host: message.parameter(4), realname: message.parameters.count > 8 ? message.trailing : nil)
    }

    private func applyWho(_ flags: String, nick: String, in buffer: Buffer, account: String?,
                          user: String?, host: String?, realname: String?) {
        addMember(Member(nick: nick, account: account, realname: realname, user: user, host: host), to: buffer)
        let botMode = isupport.botMode ?? "B"
        buffer.updateMember(nick, equals: equal) {
            $0.isAway = flags.hasPrefix("G")
            if flags.contains(botMode) { $0.isBot = true }
        }
    }

    func addMember(_ member: Member, to buffer: Buffer, replacePrefix: Bool = false) {
        if let index = buffer.members.firstIndex(where: { equal($0.nick, member.nick) }) {
            if replacePrefix { buffer.members[index].prefixes = member.prefixes }
            if let account = member.account { buffer.members[index].account = account }
            if let realname = member.realname { buffer.members[index].realname = realname }
            if let user = member.user { buffer.members[index].user = user }
            if let host = member.host { buffer.members[index].host = host }
        } else {
            buffer.members.append(member)
        }
    }

    func removeMember(_ nick: String, from buffer: Buffer) {
        buffer.members.removeAll { equal($0.nick, nick) }
    }

    // MARK: - Batches

    func handleBatch(_ message: IRCMessage) {
        guard let reference = message.first else { return }
        if reference.hasPrefix("+") {
            let ref = String(reference.dropFirst())
            let type = message.parameter(1) ?? ""
            let isHistory = type == "chathistory"
            var info = BatchInfo(type: type, target: message.parameter(2),
                                 parameters: Array(message.parameters.dropFirst(2)), isHistory: isHistory)
            info.parentRef = message.tags["batch"]
            // A batch nested in a history batch is history too.
            if let parent = info.parentRef, openBatches[parent]?.isHistory == true, !isHistory {
                info.isHistory = type != CapabilityName.multiline
            }
            if isHistory, let target = info.target, catchUpTargets.contains(where: { equal($0, target) }) {
                info.isCatchUp = true
            }
            if isHistory, aroundAwaitingBatch, let target = info.target,
               let context = aroundContext, equal(context.target, target) {
                info.isAroundContext = true
                aroundAwaitingBatch = false
            }
            if isHistory, let target = info.target,
               let buffer = buffer(named: target, kind: isupport.isChannel(target) ? .channel : .query,
                                   createIfMissing: false) {
                // The reply has started: no longer a request to give up on.
                buffer.historyLoadToken += 1
                if buffer.replaceWithNextPage, !info.isCatchUp, !info.isAroundContext {
                    buffer.replaceWithNextPage = false
                    buffer.resetHistory()
                    buffer.loadedHistory = true
                    buffer.isLoadingHistory = true
                }
            }
            if isHistory, !info.isAroundContext, message.tags["draft/chathistory-end"] != nil {
                info.isEndOfHistory = true
                serverSignalsHistoryEnd = true
            }
            if type == CapabilityName.multiline {
                info.multilineSource = message.source
                info.multilineTags = message.tags
            }
            if type == "netsplit" || type == "netjoin" { info.splitTime = timestamp(from: message) }
            openBatches[ref] = info
            if type == "labeled-response", let label = message.tags["label"] { labeledBatches[ref] = label }
        } else if reference.hasPrefix("-") {
            let ref = String(reference.dropFirst())
            if let label = labeledBatches.removeValue(forKey: ref) { pendingLabels[label] = nil }
            guard let info = openBatches[ref] else { return }
            switch info.type {
            case CapabilityName.multiline: finishMultiline(info)
            case "netsplit", "netjoin": finishSplit(info)
            default: break
            }
            if info.isAroundContext {
                finishAroundContext(failed: false)
            } else if info.type == "chathistory", let target = info.target,
                      let buffer = buffer(named: target, kind: isupport.isChannel(target) ? .channel : .query,
                                          createIfMissing: false) {
                finishHistoryPage(info, in: buffer)
            }
            openBatches[ref] = nil
        }
    }

    func batchInfo(for message: IRCMessage) -> BatchInfo? {
        message.tags["batch"].flatMap { openBatches[$0] }
    }

    private func accumulateMultiline(_ ref: String, _ message: IRCMessage) {
        guard var info = openBatches[ref] else { return }
        let body = message.trailing ?? ""
        if !info.multilineHasContent {
            info.multilineText = body
            info.multilineHasContent = true
        } else if message.tags["draft/multiline-concat"] != nil {
            info.multilineText += body
        } else {
            info.multilineText += "\n" + body
        }
        openBatches[ref] = info
    }

    private func finishMultiline(_ info: BatchInfo) {
        guard let target = info.target else { return }
        let parent = info.parentRef.flatMap { openBatches[$0] }
        let historical = parent?.isHistory ?? false
        if historical, let ref = info.parentRef { openBatches[ref]?.messageCount += 1 }
        var text = info.multilineText
        var kind: ChatLine.Kind = .message
        if text.hasPrefix("\u{01}ACTION "), text.hasSuffix("\u{01}") {
            text = String(text.dropFirst(8).dropLast())
            kind = .action
        }
        deliver(text, kind: kind, to: target, source: info.multilineSource, tags: info.multilineTags,
                historical: historical, aroundContext: parent?.isAroundContext ?? false)
    }

    /// One stage direction for a whole netsplit/netjoin, in every channel it touched.
    private func finishSplit(_ info: BatchInfo) {
        guard !info.splitNicks.isEmpty else { return }
        let servers = info.parameters.prefix(2).joined(separator: " ↔ ")
        let direction = Direction.split(servers: servers, nicks: info.splitNicks, rejoined: info.type == "netjoin")
        for buffer in buffers where info.splitBuffers.contains(buffer.id) {
            buffer.append(ChatLine(timestamp: info.splitTime ?? Date(), sender: nil, text: "", kind: .event,
                                   direction: direction), markUnread: false)
        }
    }

    // MARK: - Tags, invites, redaction, bouncer

    func handleTagMsg(_ message: IRCMessage) {
        guard let target = message.first, let source = message.source else { return }
        let isSelf = equal(source.nick, currentNick)
        let place = self.target(for: target, from: source.nick, isSelf: isSelf)
        guard let buffer = buffer(named: place.name, kind: place.kind, createIfMissing: false) else { return }
        if let mid = message.tags["msgid"], !buffer.markProcessed(mid) { return }
        if !isSelf, isIgnored(nick: source.nick, user: source.user, host: source.host,
                              account: message.tags["account"]) { return }
        if let emoji = message.tags["+draft/react"] ?? message.tags["+react"], let msgid = replyRef(message.tags) {
            buffer.addReaction(emoji, toMsgID: msgid, from: source.nick)
        }
        if let emoji = message.tags["+draft/unreact"] ?? message.tags["+unreact"], let msgid = replyRef(message.tags) {
            buffer.removeReaction(emoji, fromMsgID: msgid, by: source.nick)
        }
        if let typing = message.tags["+typing"] ?? message.tags["+draft/typing"], !isSelf,
           batchInfo(for: message)?.isHistory != true {
            switch typing {
            case "active", "paused": buffer.typing[source.nick] = Date()
            case "done": buffer.typing[source.nick] = nil
            default: break
            }
        }
    }

    func handleInvite(_ message: IRCMessage) {
        guard let invitee = message.first, let channel = message.parameter(1),
              let source = message.source else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        if equal(invitee, currentNick) {
            guard !isIgnored(nick: source.nick, user: source.user, host: source.host,
                             account: message.tags["account"]) else { return }
            lastInvite = channel
            appendDirection(.invite(by: source.nick, nick: invitee, channel: channel), to: statusBuffer,
                            message: message, historical: historical, force: true)
            guard !historical else { return }
            onNotifiableEvent?(NotifiableEvent(kind: .invite, sessionID: id, bufferID: statusBuffer.id,
                                               title: String(localized: "Invitation to \(channel)"), sender: source.nick,
                                               text: String(localized: "\(source.nick) invites you to \(channel). Type /join to go in.")))
        } else if let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) {
            appendDirection(.invite(by: source.nick, nick: invitee, channel: channel), to: buffer,
                            message: message, historical: historical, force: true)
        }
    }

    func handleRedact(_ message: IRCMessage) {
        guard let target = message.first, let msgid = message.parameter(1) else { return }
        let reason = message.parameters.count > 2 ? message.trailing : nil
        let by = message.source?.nick
        let place = self.target(for: target, from: by ?? target, isSelf: equal(by ?? "", currentNick))
        buffer(named: place.name, kind: place.kind, createIfMissing: false)?.redact(msgid: msgid, by: by, reason: reason)
    }

    func handleBouncer(_ message: IRCMessage) {
        guard message.parameter(0)?.uppercased() == "NETWORK", let netID = message.parameter(1) else { return }
        let raw = message.parameter(2) ?? "*"
        if raw == "*" {
            bouncerNetworks.removeAll { $0.id == netID }
            onBouncerNetworksChanged?()
            return
        }
        var attributes = bouncerNetworks.first { $0.id == netID }?.attributes ?? [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first else { continue }
            attributes[key] = kv.count > 1 ? kv[1] : nil
        }
        let network = BouncerNetwork(id: netID, name: attributes["name"] ?? netID, state: attributes["state"],
                                     host: attributes["host"], nickname: attributes["nickname"],
                                     attributes: attributes)
        if let index = bouncerNetworks.firstIndex(where: { $0.id == netID }) {
            bouncerNetworks[index] = network
        } else {
            bouncerNetworks.append(network)
        }
        onBouncerNetworksChanged?()
    }

    // MARK: - Standard replies & WHOIS

    func handleStandardReply(_ message: IRCMessage) {
        let command = message.first ?? "*"
        let code = message.parameter(1) ?? ""
        let description = message.trailing ?? ""
        let label = message.tags["label"] ?? message.tags["batch"].flatMap { labeledBatches[$0] }
        let origin = label.flatMap { pendingLabels[$0] }
        if message.command == "FAIL", let label { failPendingEverywhere(label) }
        if message.command == "FAIL", command == "CHATHISTORY" {
            if aroundContext?.isLoading == true { finishAroundContext(failed: true) }
            for buffer in buffers { buffer.isLoadingHistory = false }
            catchUpTargets.removeAll()
            if let seek = originalSeek {
                originalSeek = nil
                failOriginal(seek.msgid, in: seek.bufferName)
            }
            // A failed LATEST for a channel we don't hold isn't worth shouting about.
            if code == "INVALID_TARGET" { return }
        }
        let prefix = origin.map { "\($0): " } ?? (command == "*" ? "" : "\(command): ")
        addStatus("\(prefix)\(description) (\(code))", kind: message.command == "NOTE" ? .event : .error)
    }

    private func failPendingEverywhere(_ label: String) {
        for buffer in buffers { buffer.failPending(label: label) }
    }

    func handleWhoisNumeric(_ numeric: IRCNumeric, _ message: IRCMessage) {
        guard let nick = message.parameter(1) else { return }
        // 301 also arrives when messaging someone away: note it in the query.
        if numeric == .away, pendingWhois == nil || !equal(pendingWhois!.nick, nick) {
            if let query = buffer(named: nick, kind: .query, createIfMissing: false) {
                note(String(localized: "\(nick) is away: \(message.trailing ?? "")"), in: query)
            }
            return
        }
        var card = pendingWhois.flatMap { equal($0.nick, nick) ? $0 : nil } ?? WhoisCard(nick: nick)
        switch numeric {
        case .whoisUser:
            card.user = message.parameter(2)
            card.host = message.parameter(3)
            card.realname = message.trailing
        case .whoisServer: card.server = message.parameter(2)
        case .whoisOperator: card.isOperator = true
        case .whoisIdle:
            card.idle = message.parameter(2).flatMap(TimeInterval.init)
            card.signon = message.parameter(3).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        case .whoisChannels:
            card.channels += (message.trailing ?? "").split(separator: " ").map(String.init)
        case .whoisAccount: card.account = message.parameter(2)
        case .whoisSecure: card.isSecure = true
        case .whoisBot: card.isBot = true
        case .whoisCertFP: card.certFP = message.trailing?.split(separator: " ").last.map(String.init)
        case .away: card.away = message.trailing
        case .endOfWhois:
            whois = card
            pendingWhois = nil
            if card.isBot {
                for buffer in buffers where buffer.kind == .channel {
                    buffer.updateMember(nick, equals: equal) { $0.isBot = true }
                }
            }
            return
        default:
            if let text = message.trailing { card.extra.append(text) }
        }
        pendingWhois = card
    }
}
