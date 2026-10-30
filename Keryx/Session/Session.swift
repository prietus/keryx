import Foundation
import Observation
import KeryxProtocol

/// Something worth telling the user about outside the window.
struct NotifiableEvent: Sendable {
    enum Kind: Sendable { case mention, directMessage, invite, buddyOnline }
    var kind: Kind
    var sessionID: UUID
    var bufferID: UUID
    var title: String
    var sender: String
    var text: String
}

/// One live connection: registration (CAP/SASL), dispatch of inbound messages
/// into buffers, and the observable state the views read.
@MainActor
@Observable
final class Session: Identifiable {
    enum Status: Equatable, Sendable {
        case offline
        case connecting
        case registering
        case connected
        case waitingToReconnect(Date)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .connecting, .registering, .connected: return true
            default: return false
            }
        }
    }

    let id: UUID
    internal(set) var config: SessionConfig
    internal(set) var status: Status = .offline
    internal(set) var currentNick: String
    internal(set) var isupport = ISupport()
    internal(set) var enabledCaps: Set<String> = []
    internal(set) var isAway = false

    /// All conversations, status window first.
    internal(set) var buffers: [Buffer]
    let statusBuffer: Buffer
    let protocolLog = ProtocolLog()

    internal(set) var bouncerNetworks: [BouncerNetwork] = []
    internal(set) var buddies: [Buddy] = []
    internal(set) var whois: WhoisCard?
    internal(set) var aroundContext: AroundContext?
    internal(set) var jumpRequest: JumpRequest?
    /// Other users' profiles (`draft/metadata-2`), folded nick → key → value.
    internal(set) var userMetadata: [String: [String: String]] = [:]
    internal(set) var state: NetworkState

    // Hooks wired by the app model.
    var onNotifiableEvent: ((NotifiableEvent) -> Void)?
    var onIndexLine: ((ChatLine, Buffer, Session) -> Void)?
    var onBouncerNetworksChanged: (() -> Void)?
    var highlightWords: () -> [String] = { [] }
    /// Whether the user is looking at this conversation right now (selected,
    /// with Keryx in front). What arrives there isn't unread.
    var isViewing: (Buffer) -> Bool = { _ in false }
    /// Pending debounced MARKREADs, by buffer.
    var readSoon: [UUID: Task<Void, Never>] = [:]

    struct JumpRequest: Equatable {
        var bufferID: UUID
        var lineID: UUID
    }

    // MARK: Internal bookkeeping (shared with the extensions)

    let connection: any IRCTransport
    var negotiator: CapabilityNegotiator
    var didCaptureCaps = false
    var eventTask: Task<Void, Never>?
    var bufferIndex: [String: Buffer] = [:]
    var openBatches: [String: BatchInfo] = [:]
    var typingSent: [String: Date] = [:]
    var labelCounter = 0
    var pendingLabels: [String: String] = [:]
    var labeledBatches: [String: String] = [:]
    var catchUpTargets: Set<String> = []
    var catchUpPages: [String: Int] = [:]
    var serverSignalsHistoryEnd = false
    var aroundAwaitingBatch = false
    var originalSeek: (bufferKey: String, bufferName: String, msgid: String, pagesLeft: Int)?
    var multilineCounter = 0
    var monitored: Set<String> = []
    var monitorStarted = false
    var metadataSyncing: Set<String> = []
    var metadataActive: Set<String> = []
    var metadataServerState: [String: [String: String]] = [:]
    var isAuthenticated = false
    var wantsConnection = false
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?
    var keepaliveTask: Task<Void, Never>?
    var lastInbound = Date()
    var didWarnClientTagDeny = false
    var pendingWhois: WhoisCard?
    /// STS told us to move to TLS: the next connect uses this port with TLS.
    var stsUpgradePort: UInt16?
    /// The latest channel we were invited to; a bare `/join` accepts it.
    var lastInvite: String?

    struct BatchInfo {
        var type: String
        var target: String?
        var parameters: [String] = []
        var isHistory: Bool
        var messageCount = 0
        var isCatchUp = false
        var isEndOfHistory = false
        var isAroundContext = false
        var parentRef: String?
        var multilineSource: IRCSource?
        var multilineTags: [String: String] = [:]
        var multilineText = ""
        var multilineHasContent = false
        /// netsplit / netjoin: the nicks that quit or came back inside it.
        var splitNicks: [String] = []
        var splitBuffers: Set<UUID> = []
        var splitTime: Date?
    }

    static let historyPageSize = 100
    static let maxCatchUpPages = 10
    static let maxSeekPages = 5
    static let aroundContextSize = 30
    static let whoxToken = "742"
    static let version = "Keryx 0.1 for macOS"

    static let timeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(config: SessionConfig, transport: any IRCTransport = IRCConnection()) {
        connection = transport
        id = config.id
        self.config = config
        currentNick = config.nickname
        negotiator = CapabilityNegotiator(desired: config.desiredCaps, mechanism: config.saslMechanism)
        state = NetworkState.load(config.id)
        let status = Buffer(name: config.name.isEmpty ? config.host : config.name, kind: .status)
        statusBuffer = status
        buffers = [status]
        bufferIndex["*"] = status
        buddies = state.buddies.map { Buddy(nick: $0) }
    }

    var displayName: String { config.name.isEmpty ? config.host : config.name }
    var isBouncerControl: Bool { enabledCaps.contains(CapabilityName.bouncerNetworks) }

    // MARK: - Lifecycle

    func refreshConfig(_ newConfig: SessionConfig) {
        guard !status.isActive else { return }
        config = newConfig
        currentNick = newConfig.nickname
    }

    func connect() {
        wantsConnection = true
        reconnectTask?.cancel()
        guard !status.isActive else { return }
        status = .connecting
        didCaptureCaps = false
        didWarnClientTagDeny = false
        serverSignalsHistoryEnd = false
        metadataSyncing = []
        metadataActive = []
        metadataServerState = [:]
        isAuthenticated = false
        monitored = []
        monitorStarted = false
        openBatches = [:]
        enabledCaps = []
        isupport = ISupport()
        negotiator = CapabilityNegotiator(desired: config.desiredCaps, mechanism: config.saslMechanism)
        let endpoint = resolvedEndpointParameters()
        addStatus(endpoint.tls ? String(localized: "Connecting to \(config.host):\(Int(endpoint.port)) (TLS)…")
                         : String(localized: "Connecting to \(config.host):\(Int(endpoint.port))…"))
        eventTask = Task { [weak self] in await self?.runEventLoop() }
    }

    func disconnect(message: String = "Keryx") {
        wantsConnection = false
        reconnectTask?.cancel()
        keepaliveTask?.cancel()
        if status.isActive {
            let transport = connection
            Task {
                await transport.send(.quit(message))
                await transport.disconnect()
            }
        }
        eventTask?.cancel()
        status = .offline
        for buffer in buffers { buffer.isJoined = false }
    }

    /// TLS and port after applying a stored or just-received STS policy.
    private func resolvedEndpointParameters() -> (port: UInt16, tls: Bool) {
        if let port = stsUpgradePort { return (port, true) }
        if !config.useTLS, let policy = STSStore.policy(for: config.host) { return (policy.port, true) }
        return (config.port, config.useTLS)
    }

    private func runEventLoop() async {
        let endpoint: IRCConnection.Endpoint
        do {
            endpoint = try makeEndpoint()
        } catch {
            status = .failed(error.localizedDescription)
            addStatus(error.localizedDescription, kind: .error)
            return
        }
        let stream = await connection.open(endpoint)
        for await event in stream {
            switch event {
            case .connecting:
                status = .connecting
            case .ready:
                status = .registering
                lastInbound = Date()
                await beginRegistration()
            case let .message(message):
                lastInbound = Date()
                handle(message)
            case let .raw(line, outgoing):
                protocolLog.append(line, outgoing: outgoing)
            case let .error(text):
                addStatus(text, kind: .error)
            case .closed:
                connectionClosed()
            }
        }
    }

    private func connectionClosed() {
        keepaliveTask?.cancel()
        for buffer in buffers {
            buffer.isJoined = false
            buffer.isLoadingHistory = false
        }
        guard wantsConnection else {
            status = .offline
            addStatus(String(localized: "Disconnected."))
            return
        }
        if stsUpgradePort != nil {
            addStatus(String(localized: "The server requires TLS (STS); reconnecting securely…"))
            status = .offline
            connect()
            return
        }
        // Back off: 2, 4, 8… up to a minute between attempts.
        reconnectAttempt += 1
        let delay = min(60, pow(2, Double(min(reconnectAttempt, 6))))
        let when = Date().addingTimeInterval(delay)
        status = .waitingToReconnect(when)
        addStatus(String(localized: "Connection lost. Retrying in \(Int(delay)) s."))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.wantsConnection else { return }
            self.status = .offline
            self.connect()
        }
    }

    /// Re-dials at once (e.g. after the Mac wakes) if we wanted to be online.
    func reconnectIfDropped() {
        guard wantsConnection, !status.isActive else { return }
        reconnectTask?.cancel()
        status = .offline
        connect()
    }

    private func makeEndpoint() throws -> IRCConnection.Endpoint {
        var identity: TLSIdentity?
        if let data = config.certificateData {
            identity = try TLSIdentity(pkcs12: data, passphrase: config.certificatePassphrase ?? "")
        }
        let (port, tls) = resolvedEndpointParameters()
        return IRCConnection.Endpoint(host: config.host, port: port, useTLS: tls,
                                      allowInvalidCertificates: config.allowInvalidCertificates,
                                      clientIdentity: identity)
    }

    private func beginRegistration() async {
        if let password = config.serverPassword, !password.isEmpty {
            await connection.send(.pass(password))
        }
        for message in negotiator.start() { await connection.send(message) }
        await connection.send(.nick(config.nickname))
        await connection.send(.user(config.username, realName: config.realName))
    }

    /// PINGs a quiet link and drops it if the server stops answering, so a
    /// dead TCP connection (sleep, Wi-Fi change) is noticed and redialled.
    func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.status == .connected else { return }
                let quiet = Date().timeIntervalSince(self.lastInbound)
                if quiet > 240 {
                    self.addStatus(String(localized: "The server isn’t answering; reconnecting."), kind: .error)
                    await self.connection.disconnect()
                    return
                } else if quiet > 90 {
                    self.send(.ping("keryx"))
                }
            }
        }
    }

    // MARK: - Sending

    func send(_ message: IRCMessage) {
        let transport = connection
        Task { await transport.send(message) }
    }

    func nextLabel() -> String {
        labelCounter += 1
        return "k\(labelCounter)"
    }

    /// Sends a command with a `label` when labeled-response is on, so its
    /// reply (FAIL, ACK, a batch) can be tied back to it.
    @discardableResult
    func sendLabeled(_ message: IRCMessage, describedAs description: String) -> String? {
        guard enabledCaps.contains(CapabilityName.labeledResponse) else {
            send(message)
            return nil
        }
        let label = nextLabel()
        pendingLabels[label] = description
        var labeled = message
        labeled.tags["label"] = label
        send(labeled)
        return label
    }

    // MARK: - Inbound dispatch

    func handle(_ message: IRCMessage) {
        if !negotiator.isFinished {
            for response in negotiator.handle(message) { send(response) }
            if message.command == "CAP", message.parameter(1)?.uppercased() == "LS" { applySTS() }
            if negotiator.isFinished { captureNegotiationResult() }
        }

        if let ref = message.tags["batch"], openBatches[ref]?.isAroundContext == true,
           !["PRIVMSG", "NOTICE", "BATCH"].contains(message.command) {
            return
        }
        if let ref = message.tags["batch"], openBatches[ref]?.isHistory == true,
           !["PRIVMSG", "NOTICE", "BATCH"].contains(message.command) {
            openBatches[ref]?.messageCount += 1
        }

        switch message.command {
        case "PING": send(.pong(message.trailing ?? ""))
        case "PONG": break
        case "PRIVMSG": handlePrivmsg(message, isNotice: false)
        case "NOTICE": handlePrivmsg(message, isNotice: true)
        case "JOIN": handleJoin(message)
        case "PART": handlePart(message)
        case "QUIT": handleQuit(message)
        case "KICK": handleKick(message)
        case "NICK": handleNick(message)
        case "AWAY": handleAway(message)
        case "ACCOUNT": handleAccount(message)
        case "CHGHOST": handleChghost(message)
        case "SETNAME": handleSetname(message)
        case "CAP": handleCapChange(message)
        case "TOPIC": handleTopic(message)
        case "MODE": handleMode(message)
        case "BATCH": handleBatch(message)
        case "BOUNCER": handleBouncer(message)
        case "MARKREAD": handleMarkRead(message)
        case "TAGMSG": handleTagMsg(message)
        case "INVITE": handleInvite(message)
        case "REDACT": handleRedact(message)
        case "CHATHISTORY": handleChathistoryTargets(message)
        case "METADATA":
            if let target = message.first, let key = message.parameter(1) {
                handleMetadata(target: target, key: key, value: message.parameter(3))
            }
        case "FAIL", "WARN", "NOTE": handleStandardReply(message)
        case "ACK":
            if let label = message.tags["label"] { pendingLabels[label] = nil }
        case "ERROR":
            addStatus(message.trailing ?? "ERROR", kind: .error)
        default:
            if let numeric = message.numeric {
                handleNumeric(numeric, message)
            } else if message.command.count == 3, Int(message.command) != nil {
                handleUnknownNumeric(message)
            }
        }
    }

    /// STS: on plaintext, a policy with a port means reconnect with TLS now;
    /// on TLS, a duration means remember to never go plaintext to this host.
    private func applySTS() {
        guard let policy = negotiator.stsPolicy else { return }
        let onTLS = config.useTLS || stsUpgradePort != nil || STSStore.policy(for: config.host) != nil
        if !onTLS, let port = policy.port {
            stsUpgradePort = port
            Task { await connection.disconnect() }
        } else if onTLS, let duration = policy.duration {
            let port = stsUpgradePort ?? (config.useTLS ? config.port : STSStore.policy(for: config.host)?.port ?? 6697)
            STSStore.record(host: config.host, port: port, duration: duration)
        }
    }

    private func captureNegotiationResult() {
        guard !didCaptureCaps else { return }
        didCaptureCaps = true
        enabledCaps = negotiator.enabled
        if case let .failed(reason) = negotiator.saslResult {
            addStatus(String(localized: "SASL authentication failed: \(reason)"), kind: .error)
        } else if case .succeeded = negotiator.saslResult {
            isAuthenticated = true
            addStatus(String(localized: "Authenticated with SASL \(negotiator.activeMechanism?.name ?? "")."))
        }
        if enabledCaps.contains(CapabilityName.bouncerNetworks), config.boundNetworkID == nil {
            send(IRCMessage(command: "BOUNCER", parameters: ["LISTNETWORKS"]))
        }
    }

    /// cap-notify after registration: the negotiator is spent, so NEW/DEL/ACK
    /// are applied here.
    private func handleCapChange(_ message: IRCMessage) {
        guard negotiator.isFinished, didCaptureCaps, message.parameters.count >= 2 else { return }
        let names = (message.parameter(2) ?? "").split(separator: " ")
            .map { String($0.split(separator: "=").first ?? $0) }
        switch message.parameters[1].uppercased() {
        case "NEW":
            let wanted = names.filter {
                $0 != CapabilityName.sasl && config.desiredCaps.contains($0) && !enabledCaps.contains($0)
            }
            if !wanted.isEmpty { send(.capReq(wanted.sorted())) }
        case "ACK":
            for name in names {
                if name.hasPrefix("-") { enabledCaps.remove(String(name.dropFirst())) } else { enabledCaps.insert(name) }
            }
        case "DEL":
            for name in names { enabledCaps.remove(name) }
        default:
            break
        }
    }

    // MARK: - Numerics

    private func handleNumeric(_ numeric: IRCNumeric, _ message: IRCMessage) {
        switch numeric {
        case .welcome:
            status = .connected
            reconnectAttempt = 0
            stsUpgradePort = nil
            if let nick = message.first { currentNick = nick }
            addStatus(message.trailing ?? String(localized: "Connected."))
            startKeepalive()
            // The soju control connection has no channels of its own: those
            // belong to the per-network sessions, and soju rejects JOIN here.
            let isControl = isBouncerControl && config.boundNetworkID == nil
            if !isControl { autoJoin() }
            subscribeMetadata()
            publishProfile()
            if !isControl { requestTargets() }
            for buffer in buffers where buffer.kind == .query && buffer.loadedHistory {
                requestHistory(for: buffer)
            }
        case .iSupport:
            isupport.apply(message)
            warnIfClientTagsDenied()
        case .topic:
            if let channel = message.parameter(1),
               let buffer = buffer(named: channel, kind: .channel, createIfMissing: true) {
                buffer.topic = message.trailing
            }
        case .topicWhoTime:
            if let channel = message.parameter(1), let who = message.parameter(2) {
                buffer(named: channel, kind: .channel, createIfMissing: false)?.topicSetBy =
                    IRCSource(parsing: Substring(who)).nick
            }
        case .noTopic:
            if let channel = message.parameter(1) {
                buffer(named: channel, kind: .channel, createIfMissing: false)?.topic = nil
            }
        case .namReply: handleNamesReply(message)
        case .endOfNames:
            if let channel = message.parameter(1) {
                buffer(named: channel, kind: .channel, createIfMissing: false)?.membersLoaded = true
            }
        case .whoReply: handleWhoReply(message)
        case .whoSpcRpl: handleWhoxReply(message)
        case .endOfWho: break
        case .loggedIn:
            isAuthenticated = true
            addStatus(message.trailing ?? String(localized: "Logged in."))
        case .loggedOut:
            isAuthenticated = false
            addStatus(message.trailing ?? String(localized: "Logged out."))
        case .keyValue:
            if message.parameters.count >= 4 {
                handleMetadata(target: message.parameters[1], key: message.parameters[2],
                               value: message.parameters.count > 4 ? message.parameters[4] : nil)
            }
        case .metadataSubOK:
            for key in message.parameters.dropFirst().map({ $0.lowercased() }) where metadataSyncing.contains(key) {
                finishMetadataSync(key)
            }
        case .metadataUnsubOK, .metadataSubs: break
        case .metadataSyncLater:
            if let target = message.parameter(1) {
                let delay = min(max(Int(message.parameter(2) ?? "") ?? 5, 0), 60)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.status == .connected else { return }
                    self.send(IRCMessage(command: "METADATA", parameters: [target, "SYNC"]))
                }
            }
        case .inviting:
            if let nick = message.parameter(1), let channel = message.parameter(2) {
                note(String(localized: "Invited \(nick) to \(channel)."),
                     in: buffer(named: channel, kind: .channel, createIfMissing: false) ?? statusBuffer)
            }
        case .motd, .motdStart:
            if let line = message.trailing { addStatus(line, kind: .motd) }
        case .endOfMotd, .noMotd:
            if numeric == .noMotd, let line = message.trailing { addStatus(line, kind: .motd) }
            startMonitoring()
        case .monOnline, .monOffline:
            let online = numeric == .monOnline
            for entry in (message.trailing ?? "").split(separator: ",") {
                setPresence(IRCSource(parsing: entry).nick, online: online)
            }
        case .monList, .endOfMonList: break
        case .monListFull:
            addStatus(String(localized: "The server’s contact list is full."), kind: .error)
        case .nowAway:
            isAway = true
            addStatus(String(localized: "You’re now marked as away."))
        case .unaway:
            isAway = false
            addStatus(String(localized: "You’re no longer marked as away."))
        case .nicknameInUse, .erroneousNick, .unavailResource, .nickCollision:
            if status != .connected {
                currentNick += "_"
                send(.nick(currentNick))
            } else {
                addStatus(message.parameters.dropFirst().joined(separator: " "), kind: .error)
            }
        case .away, .whoisUser, .whoisServer, .whoisOperator, .whoisIdle, .whoisChannels, .whoisAccount,
             .whoisSecure, .whoisBot, .whoisCertFP, .whoisHost, .whoisActually, .whoisModes, .endOfWhois:
            handleWhoisNumeric(numeric, message)
        case .channelModeIs, .creationTime, .umodeIs:
            note(message.parameters.dropFirst().joined(separator: " "), in: statusBuffer)
        case .noSuchNick, .noSuchChannel, .cannotSendToChan, .notOnChannel, .userNotInChannel,
             .channelIsFull, .inviteOnlyChan, .bannedFromChan, .badChannelKey, .needReggedNick,
             .chanOpPrivsNeeded:
            let target = message.parameter(1)
            let text = [target, message.trailing].compactMap { $0 }.joined(separator: ": ")
            let place = target.flatMap { buffer(named: $0, kind: isupport.isChannel($0) ? .channel : .query,
                                                createIfMissing: false) } ?? statusBuffer
            note(text, in: place, kind: .error)
        default:
            if numeric.rawValue >= 400 && !numeric.endsSASL && numeric != .saslMechs {
                addStatus(message.parameters.dropFirst().joined(separator: " "), kind: .error)
            }
        }
    }

    private func handleUnknownNumeric(_ message: IRCMessage) {
        let text = message.parameters.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { return }
        let code = Int(message.command) ?? 0
        addStatus(text, kind: code >= 400 && code < 600 ? .error : .event)
    }

    // MARK: - Helpers

    @discardableResult
    func buffer(named name: String, kind: Buffer.Kind, createIfMissing: Bool) -> Buffer? {
        let key = isupport.caseMapping.fold(name)
        if let existing = bufferIndex[key] { return existing }
        guard createIfMissing else { return nil }
        let buffer = Buffer(name: name, kind: kind)
        buffer.isHidden = { [weak self] in self?.isIgnored($0) ?? false }
        bufferIndex[key] = buffer
        buffers.append(buffer)
        if kind == .query { monitor([name]) }
        return buffer
    }

    func removeBuffer(_ buffer: Buffer) {
        guard buffer.kind != .status else { return }
        if buffer.kind == .query, !isBuddy(buffer.name) { unmonitor(buffer.name) }
        bufferIndex[isupport.caseMapping.fold(buffer.name)] = nil
        buffers.removeAll { $0.id == buffer.id }
    }

    func renameQuery(from old: String, to new: String) {
        guard let query = buffer(named: old, kind: .query, createIfMissing: false),
              bufferIndex[isupport.caseMapping.fold(new)] == nil else { return }
        bufferIndex[isupport.caseMapping.fold(old)] = nil
        query.rename(new)
        bufferIndex[isupport.caseMapping.fold(new)] = query
    }

    func target(for name: String, from sender: String, isSelf: Bool) -> (name: String, kind: Buffer.Kind) {
        if isupport.isChannel(name) { return (name, .channel) }
        return (isSelf ? name : sender, .query)
    }

    func timestamp(from message: IRCMessage) -> Date {
        message.tags["time"].flatMap(Self.timeFormatter.date(from:)) ?? Date()
    }

    func addStatus(_ text: String, kind: ChatLine.Kind = .event) {
        statusBuffer.append(ChatLine(timestamp: Date(), sender: nil, text: text, kind: kind), markUnread: false)
    }

    func note(_ text: String, in buffer: Buffer, kind: ChatLine.Kind = .event) {
        buffer.append(ChatLine(timestamp: Date(), sender: nil, text: text, kind: kind), markUnread: false)
    }

    func equal(_ a: String, _ b: String) -> Bool { isupport.equalIdentifiers(a, b) }
    func fold(_ s: String) -> String { isupport.caseMapping.fold(s) }

    /// Whether `body` names us or one of the highlight words, on word
    /// boundaries and case-insensitively (`irkt` won't fire inside `quirkt`).
    func isHighlight(_ body: String) -> Bool {
        let words = [currentNick] + highlightWords()
        let lower = body.lowercased()
        for word in words where !word.isEmpty {
            let needle = word.lowercased()
            var searchRange = lower.startIndex..<lower.endIndex
            while let range = lower.range(of: needle, range: searchRange) {
                let before = range.lowerBound == lower.startIndex ? nil : lower[lower.index(before: range.lowerBound)]
                let after = range.upperBound == lower.endIndex ? nil : lower[range.upperBound]
                let isWordChar: (Character?) -> Bool = { c in
                    guard let c else { return false }
                    return c.isLetter || c.isNumber || c == "_"
                }
                if !isWordChar(before) && !isWordChar(after) { return true }
                searchRange = range.upperBound..<lower.endIndex
            }
        }
        return false
    }

    func emitNotification(_ kind: NotifiableEvent.Kind, buffer: Buffer, sender: String, text: String) {
        guard !isMuted(buffer.name) else { return }
        onNotifiableEvent?(NotifiableEvent(
            kind: kind, sessionID: id, bufferID: buffer.id,
            title: kind == .directMessage ? sender : String(localized: "\(sender) in \(buffer.name)"),
            sender: sender, text: text))
    }

    private func autoJoin() {
        var channels = config.autoJoinChannels.filter { !$0.isEmpty }
        if !config.isBouncer {
            for buffer in buffers where buffer.kind == .channel
                && !channels.contains(where: { equal($0, buffer.name) }) {
                channels.append(buffer.name)
            }
        }
        for channel in channels { join(channel) }
    }

    private func warnIfClientTagsDenied() {
        guard !didWarnClientTagDeny, !isupport.allowsClientTag("draft/react") else { return }
        didWarnClientTagDeny = true
        addStatus(String(localized: "\(isupport.network ?? String(localized: "This network")) doesn’t relay reactions between users (CLIENTTAGDENY): only you will see them."))
    }

    func consumeJump() { jumpRequest = nil }
    func dismissWhois() { whois = nil }
}

/// The raw wire traffic of a session, for the protocol console.
@MainActor @Observable
final class ProtocolLog {
    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let line: String
        let outgoing: Bool
    }

    private(set) var entries: [Entry] = []
    private let limit = 2000

    func append(_ line: String, outgoing: Bool) {
        entries.append(Entry(line: Self.redacted(line), outgoing: outgoing))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// Passwords never reach the console.
    private static func redacted(_ line: String) -> String {
        let upper = line.uppercased()
        if upper.hasPrefix("PASS ") { return "PASS ••••" }
        if upper.hasPrefix("AUTHENTICATE "), !upper.hasPrefix("AUTHENTICATE +"),
           !["PLAIN", "EXTERNAL", "SCRAM-SHA-256"].contains(String(upper.dropFirst(13))) {
            return "AUTHENTICATE ••••"
        }
        if upper.contains(" NICKSERV ") || upper.hasPrefix("NICKSERV ") { return "NICKSERV ••••" }
        return line
    }
}
