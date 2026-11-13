import Foundation
import KeryxProtocol
import os

/// Debug builds trace history loading to the system log (channel names and
/// counts, never what was said): `log show --predicate 'subsystem == "im.keryx.mac"'`.
enum HistoryTrace {
    #if DEBUG
    private static let logger = Logger(subsystem: "im.keryx.mac", category: "history")
    #endif
    static func log(_ text: @autoclosure () -> String) {
        #if DEBUG
        let line = text()
        logger.notice("\(line, privacy: .public)")
        #endif
    }
}

extension Session {
    var hasChathistory: Bool { enabledCaps.contains(CapabilityName.chathistory) }

    /// Whether CHATHISTORY takes `msgid=` references (`MSGREFTYPES`); soju
    /// only takes timestamps.
    var acceptsMsgidReferences: Bool { isupport.messageReferenceTypes.contains("msgid") }

    // MARK: - Pages

    /// The latest page on first view; on reconnect, everything after our
    /// newest line (`AFTER`), paged forward while pages come back full.
    func requestHistory(for buffer: Buffer) {
        guard hasChathistory, status == .connected, buffer.kind != .status, !buffer.isLoadingHistory else {
            HistoryTrace.log("[\(displayName)] request \(buffer.name) SKIPPED: chathistory=\(hasChathistory) status=\(status) loading=\(buffer.isLoadingHistory)")
            return
        }
        HistoryTrace.log("[\(displayName)] request \(buffer.name): lines=\(buffer.lines.count) loaded=\(buffer.loadedHistory) replace=\(buffer.replaceWithNextPage) newest=\(String(describing: buffer.newestMessageTimestamp))")
        guard buffer.loadedHistory, !buffer.replaceWithNextPage, let newest = buffer.newestMessageTimestamp else {
            buffer.loadedHistory = true
            beginHistoryLoad(buffer)
            send(IRCMessage(command: "CHATHISTORY",
                            parameters: ["LATEST", buffer.name, "*", "\(Self.historyPageSize)"]))
            return
        }
        beginHistoryLoad(buffer)
        catchUpTargets.insert(buffer.name)
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["AFTER", buffer.name, "timestamp=\(Self.timeFormatter.string(from: newest))",
                                     "\(Self.historyPageSize)"]))
    }

    /// Marks a request as under way, and gives up on it if the server hasn't
    /// started answering in a while — otherwise one lost reply would leave
    /// the conversation unable to load history until the next reconnect.
    func beginHistoryLoad(_ buffer: Buffer) {
        buffer.isLoadingHistory = true
        buffer.historyLoadToken += 1
        let token = buffer.historyLoadToken
        Task { [weak self, weak buffer] in
            try? await Task.sleep(for: Self.historyReplyTimeout)
            guard let self, let buffer, buffer.historyLoadToken == token, buffer.isLoadingHistory else { return }
            HistoryTrace.log("[\(self.displayName)] \(buffer.name): no reply, giving up")
            buffer.isLoadingHistory = false
            self.catchUpTargets = self.catchUpTargets.filter { !self.equal($0, buffer.name) }
        }
    }

    /// A conversation with nothing in it, opened: fetch the latest page. The
    /// request made on joining may have been lost or refused.
    func loadHistoryIfEmpty(_ buffer: Buffer) {
        if buffer.lines.isEmpty {
            HistoryTrace.log("[\(displayName)] opened empty \(buffer.name): joined=\(buffer.isJoined) status=\(status)")
        } else {
            let hidden = buffer.lines.filter { isIgnored($0) }.count
            HistoryTrace.log("[\(displayName)] opened \(buffer.name): lines=\(buffer.lines.count) hiddenByIgnore=\(hidden)")
        }
        guard buffer.lines.isEmpty, buffer.kind == .query || buffer.isJoined else { return }
        requestHistory(for: buffer)
    }

    /// An older page, when the reader scrolls to the top.
    func loadMoreHistory(for buffer: Buffer) {
        guard hasChathistory, buffer.kind != .status, !buffer.isLoadingHistory, !buffer.historyExhausted,
              let oldest = buffer.lines.first(where: { !$0.isPending }) else { return }
        beginHistoryLoad(buffer)
        let selector = oldest.msgid.flatMap { acceptsMsgidReferences ? "msgid=\($0)" : nil }
            ?? "timestamp=\(Self.timeFormatter.string(from: oldest.timestamp))"
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["BEFORE", buffer.name, selector, "\(Self.historyPageSize)"]))
    }

    func finishHistoryPage(_ info: BatchInfo, in buffer: Buffer) {
        HistoryTrace.log("[\(displayName)] page end \(buffer.name): messages=\(info.messageCount) catchUp=\(info.isCatchUp) end=\(info.isEndOfHistory) lines now=\(buffer.lines.count)")
        buffer.isLoadingHistory = false
        if info.isCatchUp {
            catchUpTargets = catchUpTargets.filter { !equal($0, buffer.name) }
            continueCatchUp(buffer, fullPage: info.messageCount >= Self.historyPageSize && !info.isEndOfHistory)
        } else {
            // Servers without `draft/chathistory-end` (soju) signal the start of
            // history only by a short page.
            let reachedStart = info.isEndOfHistory || info.messageCount == 0
                || (!serverSignalsHistoryEnd && info.messageCount < Self.historyPageSize)
            if reachedStart { buffer.historyExhausted = true }
            advanceOriginalSeek(in: buffer)
        }
        if isViewing(buffer) { markRead(buffer) } else { buffer.recomputeUnread() }
    }

    private func continueCatchUp(_ buffer: Buffer, fullPage: Bool) {
        let key = fold(buffer.name)
        guard fullPage else {
            catchUpPages[key] = nil
            return
        }
        let pages = (catchUpPages[key] ?? 1) + 1
        if pages > Self.maxCatchUpPages {
            // Too big a gap to bridge: start over from the latest page. What's
            // shown stays until that page arrives, so a lost reply can't leave
            // the conversation blank.
            catchUpPages[key] = nil
            HistoryTrace.log("[\(displayName)] \(buffer.name): gap too big, will replace with latest")
            buffer.replaceWithNextPage = true
        } else {
            catchUpPages[key] = pages
        }
        requestHistory(for: buffer)
    }

    // MARK: - Conversations we missed (CHATHISTORY TARGETS)

    /// Asks which conversations had activity since we were last here, so
    /// private messages received while offline open their query.
    func requestTargets() {
        guard hasChathistory else { return }
        let local = buffers.filter { $0.kind == .query }.compactMap(\.newestMessageTimestamp).max()
        let from = local ?? Date().addingTimeInterval(-7 * 86_400)
        send(IRCMessage(command: "CHATHISTORY", parameters: [
            "TARGETS", "timestamp=\(Self.timeFormatter.string(from: from))",
            "timestamp=\(Self.timeFormatter.string(from: Date().addingTimeInterval(60)))", "50",
        ]))
    }

    /// `CHATHISTORY TARGETS <target> <timestamp>`, one per conversation.
    func handleChathistoryTargets(_ message: IRCMessage) {
        guard message.first?.uppercased() == "TARGETS", let target = message.parameter(1),
              !isupport.isChannel(target), target != "*", !target.contains("."),
              !isIgnored(nick: target, user: nil, host: nil, account: nil) else { return }
        let existed = buffer(named: target, kind: .query, createIfMissing: false) != nil
        guard let query = buffer(named: target, kind: .query, createIfMissing: true) else { return }
        if !existed || !query.loadedHistory { requestHistory(for: query) }
    }

    // MARK: - A reply's original (CHATHISTORY AROUND)

    func showOriginal(of msgid: String, in buffer: Buffer) {
        if let line = buffer.line(withMsgID: msgid) {
            jumpRequest = JumpRequest(bufferID: buffer.id, lineID: line.id)
            return
        }
        if acceptsMsgidReferences {
            loadContext(around: msgid, in: buffer)
            return
        }
        guard hasChathistory, status == .connected, !buffer.historyExhausted else {
            failOriginal(msgid, in: buffer.name)
            return
        }
        originalSeek = (fold(buffer.name), buffer.name, msgid, Self.maxSeekPages - 1)
        loadMoreHistory(for: buffer)
    }

    func advanceOriginalSeek(in buffer: Buffer) {
        guard var seek = originalSeek, seek.bufferKey == fold(buffer.name) else { return }
        if let line = buffer.line(withMsgID: seek.msgid) {
            originalSeek = nil
            jumpRequest = JumpRequest(bufferID: buffer.id, lineID: line.id)
        } else if seek.pagesLeft > 0, !buffer.historyExhausted {
            seek.pagesLeft -= 1
            originalSeek = seek
            loadMoreHistory(for: buffer)
        } else {
            originalSeek = nil
            failOriginal(seek.msgid, in: buffer.name)
        }
    }

    func failOriginal(_ msgid: String, in target: String) {
        aroundContext = AroundContext(target: target, msgid: msgid, isLoading: false, failed: true)
    }

    func loadContext(around msgid: String, in buffer: Buffer) {
        guard hasChathistory, status == .connected else {
            failOriginal(msgid, in: buffer.name)
            return
        }
        guard !buffer.isLoadingHistory else { return }
        buffer.isLoadingHistory = true
        aroundContext = AroundContext(target: buffer.name, msgid: msgid)
        aroundAwaitingBatch = true
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["AROUND", buffer.name, "msgid=\(msgid)", "\(Self.aroundContextSize)"]))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.aroundAwaitingBatch, self.aroundContext?.msgid == msgid else { return }
            self.finishAroundContext(failed: true)
        }
    }

    func dismissAroundContext() {
        if aroundContext?.isLoading == true { aroundContext?.dismissed = true } else { aroundContext = nil }
    }

    func finishAroundContext(failed: Bool) {
        guard var context = aroundContext else { return }
        aroundAwaitingBatch = false
        context.lines.sort { $0.timestamp < $1.timestamp }
        context.isLoading = false
        context.failed = failed || !context.lines.contains { $0.msgid == context.msgid }
        aroundContext = context.dismissed ? nil : context
        buffer(named: context.target, kind: isupport.isChannel(context.target) ? .channel : .query,
               createIfMissing: false)?.isLoadingHistory = false
    }

    // MARK: - On-disk scrollback

    func historySnapshot() -> HistoryStore.Snapshot {
        let kept = buffers.filter { $0.kind != .status && !$0.lines.isEmpty }.map {
            let lines = Self.linesToKeep($0.lines)
            return HistoryStore.BufferSnapshot(name: $0.name, kind: $0.kind, topic: $0.topic, readMarker: $0.readMarker,
                                               historyExhausted: $0.historyExhausted && lines.count == $0.lines.count,
                                               lines: lines)
        }
        return HistoryStore.Snapshot(buffers: kept)
    }

    /// The tail of a conversation worth saving: the last `maxLinesPerBuffer`
    /// lines that aren't joins and parts, with the joins and parts among
    /// them. Counting those too would let one netsplit in a big channel push
    /// everything anyone said out of the saved scrollback.
    static func linesToKeep(_ lines: [ChatLine]) -> [ChatLine] {
        var said = 0
        var start = lines.endIndex
        while start > lines.startIndex, said < HistoryStore.maxLinesPerBuffer,
              lines.endIndex - start < HistoryStore.maxLinesPerBuffer * 4 {
            start -= 1
            if lines[start].direction?.isPresence != true { said += 1 }
        }
        return Array(lines[start...])
    }

    func restoreHistory(_ snapshot: HistoryStore.Snapshot) {
        for saved in snapshot.buffers where saved.kind != .status
            && !(saved.kind == .query && saved.name.contains(".")) {
            guard let buffer = buffer(named: saved.name, kind: saved.kind, createIfMissing: true),
                  buffer.lines.isEmpty else { continue }
            buffer.restore(saved)
        }
    }

    // MARK: - Read markers (draft/read-marker)

    /// Marks read a conversation you're reading, a moment after the last line
    /// lands, so a busy channel sends one MARKREAD, not one per message.
    func markReadSoon(_ buffer: Buffer) {
        readSoon[buffer.id]?.cancel()
        readSoon[buffer.id] = Task { [weak self, weak buffer] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let buffer, self.isViewing(buffer) else { return }
            self.markRead(buffer)
            self.readSoon[buffer.id] = nil
        }
    }

    func markRead(_ buffer: Buffer) {
        guard buffer.kind != .status else { return }
        buffer.hasMention = false
        buffer.unreadCount = 0
        guard let newest = buffer.lines.last(where: { $0.kind.countsAsUnread && !$0.isPending }) else { return }
        if let marker = buffer.readMarker, marker >= newest.timestamp { return }
        buffer.readMarker = newest.timestamp
        guard enabledCaps.contains(CapabilityName.readMarker), status == .connected else { return }
        send(IRCMessage(command: "MARKREAD",
                        parameters: [buffer.name, "timestamp=\(Self.timeFormatter.string(from: newest.timestamp))"]))
    }

    func handleMarkRead(_ message: IRCMessage) {
        guard let target = message.first,
              let buffer = buffer(named: target, kind: isupport.isChannel(target) ? .channel : .query,
                                  createIfMissing: false) else { return }
        let arg = message.parameter(1) ?? "*"
        guard arg.hasPrefix("timestamp="),
              let date = Self.timeFormatter.date(from: String(arg.dropFirst("timestamp=".count))) else { return }
        if buffer.readMarker.map({ date > $0 }) ?? true {
            buffer.readMarker = date
            buffer.recomputeUnread()
        }
    }
}
