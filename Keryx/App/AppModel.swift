import Foundation
import Observation
import AppKit
import SwiftUI
import KeryxProtocol

/// App-wide state: saved networks, live sessions (including the per-network
/// sessions a soju account opens), the selection, and the services.
@MainActor
@Observable
final class AppModel {
    let preferences = Preferences()
    let notifier = Notifier()
    let searchIndex = SearchIndex()

    private(set) var networks: [NetworkConfig] = []
    /// Account sessions by network id, plus bound bouncer sessions by their stable id.
    private(set) var sessions: [UUID: Session] = [:]
    /// Bouncer account id → the bound sessions opened under it, in bouncer order.
    private(set) var boundSessions: [UUID: [Session]] = [:]

    var selectedSessionID: UUID?
    var selectedBufferID: UUID?

    // Overlays
    var showPalette = false
    var showGlobalSearch = false
    var showMentions = false
    var showFind = false
    var editingNetwork: NetworkConfig?
    var showMembers = true
    var showProtocolLog = false
    var editingProfile: Session?

    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var autoAway: AutoAway?

    /// The app is hosting the unit tests: it must not touch your networks.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    init() {
        // Under the tests, never load saved networks or connect to them:
        // the test host is the real app, with your real settings.
        if Self.isRunningTests { return }
        #if DEBUG
        if CommandLine.arguments.contains("-KeryxNowPlayingProbe") {
            Task {
                let outcome = await NowPlaying.shared.current()
                FileHandle.standardError.write(Data("now playing: \(outcome)\n".utf8))
                exit(0)
            }
        }
        if Self.isDemo {
            let demo = makeDemoSession()
            networks = [NetworkConfig(id: demo.id, name: "Libera", host: "irc.libera.chat", nickname: "carlos")]
            sessions[demo.id] = demo
            if let channel = demo.buffers.first(where: { $0.name == "#swift" }) {
                selectedSessionID = demo.id
                selectedBufferID = channel.id
            }
            showMentions = ProcessInfo.processInfo.environment["KERYX_DEMO_MENTIONS"] != nil
            return
        }
        #endif
        _ = NowPlaying.shared  // start hearing players' announcements for /np
        networks = NetworkStore.load()
        notifier.onOpen = { [weak self] session, buffer in
            guard let self, let s = self.sessions[session], let b = s.buffers.first(where: { $0.id == buffer }) else { return }
            self.select(b, in: s)
        }
        for network in networks {
            let session = session(for: network)
            if network.autoConnect { session.connect() }
        }
        if let first = orderedSessions.first {
            select(first.statusBuffer, in: first)
        }
        notifier.requestAuthorization()
        // Coming back to Keryx: what arrived meanwhile in the open conversation
        // is now read, and the ⁂ shows where you left off.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.selectedSession, let buffer = self.selectedBuffer else { return }
                if buffer.unreadCount > 0 { buffer.entryMarker = buffer.readMarker }
                session.markRead(buffer)
                session.loadHistoryIfEmpty(buffer)
                self.notifier.clear(buffer: buffer.id)
                self.updateBadge()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectDropped() }
        }
        autoAway = AutoAway(preferences: preferences) { [weak self] in
            self.map { Array($0.sessions.values) } ?? []
        }
        autoAway?.start()
        startAutosave()
    }

    /// A nick as shown: itself, or a stable mask in privacy mode so threads
    /// stay readable in screenshots without naming anyone.
    func shown(_ nick: String) -> String {
        guard preferences.privacyMode, !nick.isEmpty else { return nick }
        var hash: UInt32 = 2166136261
        for byte in nick.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return "u·" + String(hash % 0xFFF, radix: 16)
    }

    /// The nicks a conversation knows (members, recent speakers, you, the
    /// query's peer), cached by the conversation's size, for masking.
    private var knownNicksCache: [UUID: (key: Int, nicks: Set<String>)] = [:]

    private func knownNicks(in buffer: Buffer, of session: Session) -> Set<String> {
        let key = buffer.lines.count &* 31 &+ buffer.members.count
        if let cached = knownNicksCache[buffer.id], cached.key == key { return cached.nicks }
        var nicks = Set(buffer.members.map { $0.nick.lowercased() })
        for line in buffer.lines.suffix(500) { if let sender = line.sender { nicks.insert(sender.lowercased()) } }
        nicks.insert(session.currentNick.lowercased())
        if buffer.kind == .query { nicks.insert(buffer.name.lowercased()) }
        knownNicksCache[buffer.id] = (key, nicks)
        return nicks
    }

    /// In privacy mode, nicks named inside a message ("ana: look") are masked
    /// too, except inside links, which would break.
    func masked(_ text: String, in buffer: Buffer, of session: Session) -> String {
        guard preferences.privacyMode, !text.isEmpty else { return text }
        let known = knownNicks(in: buffer, of: session)
        let links = MessageLinks.detect(in: text).map(\.range)
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_\[\]\\`^{|}][A-Za-z0-9_\[\]\\`^{|}-]*"#) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text), known.contains(text[range].lowercased()),
                  !links.contains(where: { $0.overlaps(range) }),
                  let target = Range(match.range, in: result) else { continue }
            result.replaceSubrange(target, with: shown(String(text[range])))
        }
        return result
    }

    /// Hosts whose pages wrap a single image: your uploader and the networks' file hosts.
    var wrapperHosts: Set<String> {
        var hosts = Set(sessions.values.compactMap { $0.fileHost?.url.host() })
        if let custom = URL(string: preferences.uploaderURL)?.host() { hosts.insert(custom) }
        return hosts
    }

    /// The colour a nick is set in: its own hue, or ink when colours are off.
    /// Your own nick stays in graphite either way.
    func color(for nick: String, isSelf: Bool = false) -> Color {
        if isSelf { return Palette.graphite }
        return preferences.colorNicks ? Palette.nick(nick) : Palette.ink
    }

    // MARK: - Sessions

    /// Sidebar order: each saved network, followed by the bouncer networks it opened.
    var orderedSessions: [Session] {
        networks.flatMap { network -> [Session] in
            guard let base = sessions[network.id] else { return [] }
            let bound = boundSessions[network.id] ?? []
            // A soju account with networks is only a control connection: its
            // status window stays reachable, but conversations live in the bound ones.
            return [base] + bound
        }
    }

    var selectedSession: Session? { selectedSessionID.flatMap { sessions[$0] } }

    var selectedBuffer: Buffer? {
        guard let session = selectedSession else { return nil }
        return session.buffers.first { $0.id == selectedBufferID } ?? session.statusBuffer
    }

    @discardableResult
    private func session(for network: NetworkConfig) -> Session {
        if let existing = sessions[network.id] { return existing }
        let session = makeSession(SessionConfig(network, clientName: preferences.clientName))
        sessions[network.id] = session
        return session
    }

    private func makeSession(_ config: SessionConfig) -> Session {
        let session = Session(config: config)
        if preferences.keepHistory, let snapshot = HistoryStore.load(config.id) {
            session.restoreHistory(snapshot)
        }
        session.highlightWords = { [weak self] in self?.preferences.highlightWords ?? [] }
        session.isViewing = { [weak self] buffer in
            NSApp.isActive && self?.selectedBufferID == buffer.id
        }
        session.onNotifiableEvent = { [weak self] event in self?.deliver(event) }
        session.awayOnConnect = { [weak self] in self?.autoAway?.reasonIfAway }
        session.onIndexLine = { [weak self] line, buffer, session in self?.index(line, in: buffer, of: session) }
        session.onBouncerNetworksChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            self.syncBoundSessions(for: session)
        }
        return session
    }

    /// Opens one bound session per soju network (and closes the ones that went
    /// away), so each network appears in the sidebar with its own channels.
    private func syncBoundSessions(for control: Session) {
        guard control.config.boundNetworkID == nil else { return }
        let baseID = control.id
        var current = boundSessions[baseID] ?? []
        let wanted = control.bouncerNetworks
        for session in current where !wanted.contains(where: { SessionConfig.stableID(baseID, $0.id) == session.id }) {
            session.disconnect()
            sessions[session.id] = nil
        }
        current.removeAll { sessions[$0.id] == nil }
        for network in wanted where !current.contains(where: { $0.id == SessionConfig.stableID(baseID, network.id) }) {
            let config = SessionConfig(boundNetwork: network, base: control.config)
            let session = makeSession(config)
            sessions[session.id] = session
            current.append(session)
            session.connect()
        }
        current.sort { a, b in
            (wanted.firstIndex { SessionConfig.stableID(baseID, $0.id) == a.id } ?? 0)
                < (wanted.firstIndex { SessionConfig.stableID(baseID, $0.id) == b.id } ?? 0)
        }
        boundSessions[baseID] = current
    }

    func select(_ buffer: Buffer, in session: Session) {
        if let previous = selectedBuffer, let previousSession = selectedSession, previous.id != buffer.id {
            previousSession.markRead(previous)
            previous.entryMarker = nil
        }
        if buffer.id != selectedBufferID {
            // Remember where you'd read up to, for the ⁂, before marking it read.
            buffer.entryMarker = buffer.readMarker
        }
        selectedSessionID = session.id
        selectedBufferID = buffer.id
        session.markRead(buffer)
        session.loadMembersIfNeeded(buffer)
        if buffer.kind != .status, !buffer.loadedHistory, buffer.kind == .query { session.requestHistory(for: buffer) }
        session.loadHistoryIfEmpty(buffer)
        notifier.clear(buffer: buffer.id)
        updateBadge()
    }

    /// Steps through conversations in sidebar order (⌘⌥↑ / ⌘⌥↓).
    func selectAdjacent(_ offset: Int, unreadOnly: Bool = false) {
        let all = orderedSessions.flatMap { s in sidebarBuffers(for: s).map { (s, $0) } }
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.1.id == selectedBufferID } ?? 0
        var i = index
        for _ in 0..<all.count {
            i = (i + offset + all.count) % all.count
            if !unreadOnly || all[i].1.unreadCount > 0 || all[i].1.hasMention {
                select(all[i].1, in: all[i].0)
                return
            }
        }
    }

    /// The conversations a session lists: pinned first, then channels, then people.
    func sidebarBuffers(for session: Session) -> [Buffer] {
        let rest = session.buffers.filter { $0.kind != .status }
        let pinned = rest.filter { session.isPinned($0.name) }
        let channels = rest.filter { $0.kind == .channel && !session.isPinned($0.name) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let queries = rest.filter { $0.kind == .query && !session.isPinned($0.name) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return pinned + channels + queries
    }

    func close(_ buffer: Buffer, in session: Session) {
        let wasSelected = buffer.id == selectedBufferID
        session.part(buffer)
        if wasSelected { select(session.statusBuffer, in: session) }
    }

    /// Runs the composer's text and applies what the command asks of the UI.
    func submit(_ text: String, in buffer: Buffer, of session: Session, replyTo: String?) {
        switch session.runInput(text, in: buffer, replyTo: replyTo) {
        case .none: break
        case let .select(target): select(target, in: session)
        case let .clear(target): target.lines.removeAll()
        case let .closed(target):
            if target.id == selectedBufferID { select(session.statusBuffer, in: session) }
        case let .addHighlight(words):
            for word in words where !preferences.highlightWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                preferences.highlightWords.append(word)
            }
            session.note(String(localized: "Highlight words: \(preferences.highlightWords.formatted(.list(type: .and)))"), in: buffer)
        case let .removeHighlight(words):
            preferences.highlightWords.removeAll { w in words.contains { $0.caseInsensitiveCompare(w) == .orderedSame } }
            session.note(preferences.highlightWords.isEmpty ? String(localized: "No highlight words.")
                         : String(localized: "Highlight words: \(preferences.highlightWords.formatted(.list(type: .and)))"), in: buffer)
        case .editProfile:
            editingProfile = session
        case let .exec(target, arguments):
            runScript(arguments, in: target, of: session)
        case let .nowPlaying(target):
            Task {
                switch await NowPlaying.shared.current() {
                case let .playing(track):
                    session.sendMessage(NowPlaying.action(for: track), to: target, action: true)
                case .nothing:
                    session.note(String(localized: "Nothing is playing right now."), in: target)
                case let .notPermitted(players):
                    let names = players.formatted(.list(type: .and))
                    session.note(String(localized: "Keryx isn’t allowed to ask \(names) what’s playing. Allow it in System Settings → Privacy & Security → Automation → Keryx."),
                                 in: target, kind: .error)
                }
            }
        case .listHighlights:
            session.note(preferences.highlightWords.isEmpty
                         ? String(localized: "Only your nick highlights you. Add words with /highlight add word.")
                         : String(localized: "Your nick highlights you, and so do: \(preferences.highlightWords.formatted(.list(type: .and)))"), in: buffer)
        }
    }

    // MARK: - /exec

    private func runScript(_ arguments: String, in buffer: Buffer, of session: Session) {
        let trimmed = arguments.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            explainScripts(in: buffer, of: session)
            return
        }
        if trimmed == "-kill" {
            let stopped = ScriptRunner.shared.stopWaiting()
            session.note(stopped == 0 ? String(localized: "No script is running.")
                         : String(localized: "Stopped waiting. The script may still be running in the background."), in: buffer)
            return
        }
        guard let request = ScriptRunner.request(for: trimmed) else {
            session.note(String(localized: "Usage: /exec [-o] script [args] | -kill"), in: buffer, kind: .error)
            return
        }
        let shown = request.script == "sh" && request.arguments.count == 1
            ? request.arguments[0] : ([request.script] + request.arguments).joined(separator: " ")
        session.note("$ " + shown, in: buffer, kind: .motd)
        Task {
            switch await ScriptRunner.shared.run(request) {
            case let .finished(output, status):
                deliver(output, of: request, to: buffer, in: session)
                if let status { session.note(status, in: buffer, kind: .error) }
            case let .timedOut(output):
                deliver(output, of: request, to: buffer, in: session)
                session.note(String(localized: "Stopped waiting after 30 seconds. The script may still be running."),
                             in: buffer, kind: .error)
            case let .failed(message):
                session.note(message, in: buffer, kind: .error)
                if ScriptRunner.available().isEmpty { explainScripts(in: buffer, of: session) }
            }
        }
    }

    /// Shows the output to you, or with -o sends it (asking first if long).
    private func deliver(_ output: [String], of request: ScriptRunner.Request, to buffer: Buffer, in session: Session) {
        guard !output.isEmpty else {
            session.note(String(localized: "(no output)"), in: buffer)
            return
        }
        if request.send, buffer.kind != .status {
            guard ScriptRunner.confirmSending(output.count, to: buffer.name) else { return }
            session.sendMessage(output.joined(separator: "\n"), to: buffer)
        } else {
            for line in output { session.note(line.isEmpty ? " " : line, in: buffer, kind: .motd) }
        }
    }

    /// Where scripts go, what's there, and how to get WeeChat's /exec.
    private func explainScripts(in buffer: Buffer, of session: Session) {
        let folder = ScriptRunner.folder?.path ?? "~/Library/Application Scripts/im.keryx.mac"
        let quoted = folder.replacingOccurrences(of: " ", with: "\\ ")
        let scripts = ScriptRunner.available()
        session.note(scripts.isEmpty
                     ? String(localized: "Keryx runs the scripts you put in \(folder). There are none yet.")
                     : String(localized: "Your scripts: \(scripts.joined(separator: ", ")). Folder: \(folder)"), in: buffer)
        guard !scripts.contains("sh") else { return }
        session.note(String(localized: "To run any command, like WeeChat’s /exec, create a script called sh in Terminal:"), in: buffer)
        for line in ["mkdir -p \(quoted)",
                     "printf '#!/bin/sh\\ncd \"$HOME\" || exit 1\\nexec /bin/sh -c \"$*\"\\n' > \(quoted)/sh",
                     "chmod +x \(quoted)/sh"] {
            session.note(line, in: buffer, kind: .motd)
        }
        session.note(String(localized: "Then any command: /exec uptime   or   /exec -o ls -latr"), in: buffer)
    }

    // MARK: - Networks

    func save(_ network: NetworkConfig) {
        if let index = networks.firstIndex(where: { $0.id == network.id }) {
            networks[index] = network
        } else {
            networks.append(network)
        }
        NetworkStore.save(networks)
        let session = session(for: network)
        session.refreshConfig(SessionConfig(network, clientName: preferences.clientName))
        if !session.status.isActive {
            session.connect()
        }
        select(session.statusBuffer, in: session)
    }

    func delete(_ network: NetworkConfig) {
        for bound in boundSessions[network.id] ?? [] {
            bound.disconnect()
            sessions[bound.id] = nil
            HistoryStore.delete(bound.id)
            NetworkState.delete(bound.id)
            searchIndex.forget(network: bound.id)
        }
        boundSessions[network.id] = nil
        sessions[network.id]?.disconnect()
        sessions[network.id] = nil
        networks.removeAll { $0.id == network.id }
        NetworkStore.save(networks)
        HistoryStore.delete(network.id)
        NetworkState.delete(network.id)
        searchIndex.forget(network: network.id)
        network.forgetSecrets()
        if let first = orderedSessions.first { select(first.statusBuffer, in: first) } else {
            selectedSessionID = nil
            selectedBufferID = nil
        }
    }

    func config(for session: Session) -> NetworkConfig? {
        networks.first { $0.id == (session.config.parentID ?? session.id) }
    }

    func toggleConnection(_ session: Session) {
        if session.status.isActive || session.wantsConnection {
            session.disconnect()
            for bound in boundSessions[session.id] ?? [] { bound.disconnect() }
        } else {
            if let network = config(for: session), session.config.parentID == nil {
                session.refreshConfig(SessionConfig(network, clientName: preferences.clientName))
            }
            session.connect()
        }
    }

    private func reconnectDropped() {
        for session in sessions.values { session.reconnectIfDropped() }
    }

    // MARK: - Notifications, index, persistence

    private func deliver(_ event: NotifiableEvent) {
        updateBadge()
        let looking = NSApp.isActive && event.bufferID == selectedBufferID
        guard !looking else { return }
        switch event.kind {
        case .mention, .invite: guard preferences.notifyMentions else { return }
        case .directMessage: guard preferences.notifyDirect else { return }
        case .buddyOnline: break
        }
        notifier.present(event)
    }

    private func index(_ line: ChatLine, in buffer: Buffer, of session: Session) {
        guard line.kind.countsAsUnread, !line.text.isEmpty, let sender = line.sender else { return }
        let key = line.msgid ?? "\(session.id)/\(buffer.name)/\(line.timestamp.timeIntervalSince1970)/\(sender)/\(line.text.hashValue)"
        searchIndex.add(network: session.id, buffer: buffer.name, sender: sender, body: line.text,
                        time: line.timestamp, key: key)
    }

    func updateBadge() {
        let mentions = sessions.values.flatMap(\.buffers).filter {
            $0.hasMention || ($0.kind == .query && $0.unreadCount > 0)
        }.count
        notifier.setBadge(mentions)
    }

    private func startAutosave() {
        saveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.saveHistory()
            }
        }
    }

    func saveHistory() {
        guard preferences.keepHistory else { return }
        for (id, session) in sessions { HistoryStore.save(session.historySnapshot(), for: id) }
    }

    func quit() {
        saveHistory()
        for session in sessions.values where session.status.isActive { session.disconnect() }
    }

    /// Jumps from a search hit to its conversation.
    /// A line that named you, with where it was said.
    struct Mention: Identifiable {
        let line: ChatLine
        let buffer: Buffer
        let session: Session
        var id: UUID { line.id }
    }

    /// Every line in the loaded scrollback that mentions you, newest first.
    var mentions: [Mention] {
        sessions.values.flatMap { session in
            session.buffers.flatMap { buffer in
                buffer.lines.filter(\.mentionsMe).map { Mention(line: $0, buffer: buffer, session: session) }
            }
        }
        .sorted { $0.line.timestamp > $1.line.timestamp }
    }

    func open(_ mention: Mention) {
        select(mention.buffer, in: mention.session)
        mention.session.jumpRequest = Session.JumpRequest(bufferID: mention.buffer.id, lineID: mention.line.id)
    }

    func open(_ hit: SearchIndex.Hit) {
        guard let session = sessions[hit.network],
              let buffer = session.buffer(named: hit.buffer,
                                          kind: session.isupport.isChannel(hit.buffer) ? .channel : .query,
                                          createIfMissing: false) else { return }
        select(buffer, in: session)
        if let line = buffer.lines.min(by: {
            abs($0.timestamp.timeIntervalSince(hit.time)) < abs($1.timestamp.timeIntervalSince(hit.time))
        }) {
            session.jumpRequest = Session.JumpRequest(bufferID: buffer.id, lineID: line.id)
        }
    }
}
