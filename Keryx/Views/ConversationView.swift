import SwiftUI

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let buffer: Buffer

    @State private var replyTo: ChatLine?
    @State private var reacting: ChatLine?
    @State private var draft = ""
    @State private var drafts: [UUID: String] = [:]
    @State private var findText = ""
    @State private var composerFocus = 0
    @FocusState private var findFocused: Bool

    /// The speaker column fits the longest nick that has spoken recently.
    private var nameColumn: CGFloat {
        var nicks = Set(buffer.lines.suffix(400).compactMap(\.sender).map(model.shown))
        nicks.insert(model.shown(session.currentNick))
        return Gutter.name(for: nicks, size: model.preferences.bodySize)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ActTitle(session: session, buffer: buffer)
            if model.showFind {
                FindBar(text: $findText, focused: $findFocused) {
                    model.showFind = false
                    findText = ""
                    composerFocus += 1
                }
            }
            TranscriptView(session: session, buffer: buffer, find: model.showFind ? findText : nil,
                           replyTo: $replyTo, onReact: { reacting = $0 })
                .id(buffer.id)
            Composer(session: session, buffer: buffer, replyTo: $replyTo, text: $draft, focusToken: $composerFocus)
        }
        .environment(\.nameColumn, nameColumn)
        .background(Palette.paper)
        .onAppear {
            composerFocus += 1
            #if DEBUG
            // Through the environment: a bare argument value would be taken
            // as a file to open, and the main window wouldn't appear.
            if let demoDraft = ProcessInfo.processInfo.environment["KERYX_DEMO_DRAFT"] { draft = demoDraft }
            #endif
        }
        .onChange(of: buffer.id) { old, new in
            drafts[old] = draft
            draft = drafts[new] ?? ""
            replyTo = nil
            composerFocus += 1
        }
        .onChange(of: replyTo) { _, line in if line != nil { composerFocus += 1 } }
        .onChange(of: model.showFind) { _, show in if show { findFocused = true } }
        .popover(item: $reacting) { line in
            ReactionPicker { emoji in
                session.toggleReaction(emoji, to: line, in: buffer)
                reacting = nil
            }
        }
        .sheet(item: Binding(get: { session.whois }, set: { if $0 == nil { session.dismissWhois() } })) { card in
            WhoisSheet(card: card, session: session)
        }
        .sheet(item: Binding(get: { session.aroundContext }, set: { if $0 == nil { session.dismissAroundContext() } })) { context in
            AroundSheet(context: context, session: session)
        }
    }
}

/// The top of the page: where we are, and the channel's topic set as a headline.
private struct ActTitle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.nameColumn) private var nameColumn
    let session: Session
    let buffer: Buffer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MessageFormatter.format(headline, size: model.preferences.bodySize).text)
                .font(Typeset.body(model.preferences.bodySize))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(([MessageFormatter.plain(headline)] + [byline].compactMap { $0 }).joined(separator: "\n"))
            Spacer(minLength: 8)
            Text(dateline)
                .font(Typeset.note(model.preferences.bodySize))
                .foregroundStyle(Palette.graphite)
                .lineLimit(1)
        }
        .padding(.leading, 12 + Gutter.lead(name: nameColumn))
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 0.5) }
    }

    private var dateline: String {
        switch buffer.kind {
        case .status:
            return session.isBouncerControl ? String(localized: "Bouncer") : String(localized: "Server")
        case .channel:
            let count = buffer.members.count
            var pieces: [String] = []
            if count == 1 { pieces.append(String(localized: "1 person")) }
            if count > 1 { pieces.append(String(localized: "\(count) people")) }
            if !buffer.isJoined { pieces.append(String(localized: "not in the channel")) }
            return pieces.joined(separator: ", ")
        case .query:
            let presence: String
            switch (buffer.peerOnline, buffer.peerAway) {
            case (true?, true): presence = ", " + String(localized: "away")
            case (true?, false): presence = ", " + String(localized: "online")
            case (false?, _): presence = ", " + String(localized: "offline")
            default: presence = ""
            }
            return String(localized: "Private conversation on \(session.displayName)") + presence
        }
    }

    private var headline: String {
        switch buffer.kind {
        case .status: return session.displayName
        case .channel: return buffer.topic.flatMap { $0.isEmpty ? nil : $0 } ?? buffer.name
        case .query:
            let meta = session.metadata(for: buffer.name)
            return meta["display-name"].map { "\(model.shown(buffer.name)) (\($0))" } ?? model.shown(buffer.name)
        }
    }

    private var byline: String? {
        switch buffer.kind {
        case .channel:
            return buffer.topicSetBy.map { String(localized: "Topic by \(model.shown($0))") }
        case .query:
            let meta = session.metadata(for: buffer.name)
            let pieces = [meta["pronouns"], meta["status"]].compactMap { $0 }
            return pieces.isEmpty ? nil : pieces.joined(separator: ", ")
        case .status:
            switch session.status {
            case .connected: return String(localized: "Connected as \(model.shown(session.currentNick)), \(session.enabledCaps.count) IRCv3 capabilities")
            case .connecting, .registering: return String(localized: "Connecting…")
            case let .waitingToReconnect(date): return String(localized: "Retrying \(date.formatted(.relative(presentation: .named)))")
            case let .failed(reason): return reason
            case .offline: return String(localized: "Offline")
            }
        }
    }
}

private struct FindBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.graphite)
            TextField("Search this conversation", text: $text)
                .textFieldStyle(.plain)
                .font(Typeset.body())
                .focused($focused)
                .onKeyPress(.escape) { close(); return .handled }
            Button("Close", action: close).buttonStyle(.plain).foregroundStyle(Palette.graphite)
        }
        .padding(.horizontal, 12 + Gutter.time + Gutter.gap)
        .padding(.vertical, 8)
        .background(Palette.board)
    }
}

/// A handful of common reactions, plus any emoji from the system palette.
private struct ReactionPicker: View {
    var pick: (String) -> Void
    @State private var custom = ""

    private let common = ["👍", "❤️", "😂", "😮", "😢", "🎉", "👀", "🙏", "🔥", "✅", "🤔", "👏"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 6), spacing: 6) {
                ForEach(common, id: \.self) { emoji in
                    Button(emoji) { pick(emoji) }
                        .buttonStyle(.plain)
                        .font(Typeset.title())
                }
            }
            HStack {
                TextField("Other…", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { if let e = custom.first { pick(String(e)) } }
                Button("Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }
                    .buttonStyle(.link)
                    .font(Chrome.small)
            }
        }
        .padding(12)
    }
}

/// WHOIS, laid out like a cast list entry.
private struct WhoisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: WhoisCard
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.shown(card.nick))
                .font(Typeset.title())
            if let realname = card.realname {
                Text(realname).font(Typeset.direction()).foregroundStyle(Palette.graphite)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                row(String(localized: "Address"), [card.user, card.host].compactMap { $0 }.joined(separator: "@"))
                let meta = session.metadata(for: card.nick)
                row(String(localized: "Display name"), meta["display-name"])
                row(String(localized: "Pronouns"), meta["pronouns"])
                row(String(localized: "Status"), meta["status"])
                row(String(localized: "Homepage"), meta["homepage"])
                row(String(localized: "Account"), card.account)
                row(String(localized: "Server"), card.server)
                row(String(localized: "Channels"), card.channels.isEmpty ? nil : card.channels.joined(separator: " "))
                row(String(localized: "Idle"), card.idle.map { Duration.seconds($0).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)) })
                row(String(localized: "Online since"), card.signon?.formatted(date: .abbreviated, time: .shortened))
                row(String(localized: "Away"), card.away)
                row(String(localized: "Certificate"), card.certFP)
                let flags = [card.isOperator ? String(localized: "network operator") : nil,
                             card.isSecure ? String(localized: "encrypted connection") : nil,
                             card.isBot ? String(localized: "bot") : nil].compactMap { $0 }
                row(String(localized: "Also"), flags.isEmpty ? nil : flags.formatted(.list(type: .and)))
                ForEach(card.extra, id: \.self) { row("", $0) }
            }
            HStack {
                Button("Private conversation") {
                    model.select(session.openQuery(card.nick), in: session)
                    dismiss()
                }
                Button(session.isBuddy(card.nick) ? String(localized: "Remove from contacts") : String(localized: "Add to contacts")) {
                    if session.isBuddy(card.nick) { session.removeBuddy(card.nick) } else { session.addBuddy(card.nick) }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 480)
        .background(Palette.paper)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).font(Typeset.note()).foregroundStyle(Palette.graphite)
                Text(value).font(Typeset.body()).textSelection(.enabled)
            }
        }
    }
}

/// The messages around a reply's original, fetched on demand.
private struct AroundSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let context: AroundContext
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original message").font(Typeset.title())
            if context.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if context.failed {
                Text("The server couldn’t return it: it’s too old, it was deleted, or this network keeps no history.")
                    .font(Typeset.direction()).foregroundStyle(Palette.graphite)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(context.lines) { line in
                        (Text(verbatim: model.shown(line.sender ?? "")).font(Typeset.speaker()) + Text(verbatim: "   ")
                            + Text(MessageFormatter.format(line.text, size: Typeset.ui).text))
                            .font(Typeset.body())
                            .foregroundStyle(line.msgid == context.msgid ? Palette.bluePencil : Palette.ink)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .background(Palette.paper)
    }
}
