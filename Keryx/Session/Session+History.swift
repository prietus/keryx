import Foundation
import KeryxProtocol

extension Session {
    var hasChathistory: Bool { enabledCaps.contains(CapabilityName.chathistory) }

    /// Whether CHATHISTORY takes `msgid=` references (`MSGREFTYPES`); soju
    /// only takes timestamps.
    var acceptsMsgidReferences: Bool { isupport.messageReferenceTypes.contains("msgid") }

    // MARK: - Pages

    /// The latest page on first view; on reconnect, everything after our
    /// newest line (`AFTER`), paged forward while pages come back full.
    func requestHistory(for buffer: Buffer) {
        guard hasChathistory, !buffer.isLoadingHistory else { return }
        guard buffer.loadedHistory, let newest = buffer.newestMessageTimestamp else {
            buffer.loadedHistory = true
            buffer.isLoadingHistory = true
            send(IRCMessage(command: "CHATHISTORY",
                            parameters: ["LATEST", buffer.name, "*", "\(Self.historyPageSize)"]))
            return
        }
        buffer.isLoadingHistory = true
        catchUpTargets.insert(buffer.name)
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["AFTER", buffer.name, "timestamp=\(Self.timeFormatter.string(from: newest))",
                                     "\(Self.historyPageSize)"]))
    }

    /// An older page, when the reader scrolls to the top.
    func loadMoreHistory(for buffer: Buffer) {
        guard hasChathistory, buffer.kind != .status, !buffer.isLoadingHistory, !buffer.historyExhausted,
              let oldest = buffer.lines.first(where: { !$0.isPending }) else { return }
        buffer.isLoadingHistory = true
        let selector = oldest.msgid.flatMap { acceptsMsgidReferences ? "msgid=\($0)" : nil }
            ?? "timestamp=\(Self.timeFormatter.string(from: oldest.timestamp))"
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["BEFORE", buffer.name, selector, "\(Self.historyPageSize)"]))
    }

    func finishHistoryPage(_ info: BatchInfo, in buffer: Buffer) {
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
        buffer.recomputeUnread()
    }

    private func continueCatchUp(_ buffer: Buffer, fullPage: Bool) {
        let key = fold(buffer.name)
        guard fullPage else {
            catchUpPages[key] = nil
            return
        }
        let pages = (catchUpPages[key] ?? 1) + 1
        if pages > Self.maxCatchUpPages {
            // Too big a gap to bridge: start over from the latest page.
            catchUpPages[key] = nil
            buffer.resetHistory()
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
            HistoryStore.BufferSnapshot(name: $0.name, kind: $0.kind, topic: $0.topic, readMarker: $0.readMarker,
                                        historyExhausted: $0.historyExhausted
                                            && $0.lines.count <= HistoryStore.maxLinesPerBuffer,
                                        lines: Array($0.lines.suffix(HistoryStore.maxLinesPerBuffer)))
        }
        return HistoryStore.Snapshot(buffers: kept)
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
