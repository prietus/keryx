import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if let session = model.selectedSession, let buffer = model.selectedBuffer {
                ConversationView(session: session, buffer: buffer)
                    .id(model.preferences.serifType)
                    .inspector(isPresented: Binding(get: { model.showMembers && buffer.kind == .channel },
                                                    set: { model.showMembers = $0 })) {
                        MembersView(session: session, buffer: buffer)
                            .inspectorColumnWidth(min: 170, ideal: 210, max: 300)
                    }
                    .navigationTitle(buffer.kind == .status ? session.displayName
                                     : buffer.kind == .query ? model.shown(buffer.name) : buffer.name)
                    .navigationSubtitle(buffer.kind == .status ? "" : session.displayName)
            } else {
                Welcome()
            }
        }
        // Two light (or two dark) themes share an appearance, so nothing
        // tells the colours to redraw: set the window again instead.
        .id(model.preferences.theme)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.preferences.privacyMode {
                    Text("Privacy mode")
                        .font(Chrome.smallStrong)
                        .foregroundStyle(Palette.bluePencil)
                        .help("Nicks are shown masked (⌘⇧P)")
                }
                Button { model.showMentions = true } label: { Image(systemName: "at") }
                    .help("Mentions of you (⌘⇧M)")
                Button { model.showGlobalSearch = true } label: { Image(systemName: "text.magnifyingglass") }
                    .help("Search all history (⌘⇧F)")
                if let session = model.selectedSession, let buffer = model.selectedBuffer, buffer.kind == .channel {
                    let quiet = session.isPresenceQuiet(buffer.name) || !model.preferences.showPresence
                    Button {
                        if !model.preferences.showPresence {
                            model.preferences.showPresence = true
                            session.setPresenceQuiet(false, for: buffer.name)
                        } else {
                            session.setPresenceQuiet(!quiet, for: buffer.name)
                        }
                    } label: {
                        Image(systemName: quiet ? "arrow.left.arrow.right.circle" : "arrow.left.arrow.right.circle.fill")
                    }
                    .help(quiet ? "Show joins and parts in this channel" : "Hide joins and parts in this channel")
                    Button { model.showMembers.toggle() } label: { Image(systemName: "person.2") }
                        .help("Show or hide the cast")
                }
            }
        }
        .overlay {
            if model.showPalette {
                CommandPalette()
            }
        }
        .sheet(isPresented: $model.showGlobalSearch) { GlobalSearch() }
        .sheet(isPresented: $model.showMentions) { MentionsView() }
        .sheet(item: $model.editingNetwork) { network in NetworkEditor(network: network) }
        .sheet(item: $model.editingProfile) { session in ProfileSheet(session: session) }
        .sheet(isPresented: $model.showProtocolLog) {
            if let session = model.selectedSession { ProtocolLogView(log: session.protocolLog, title: session.displayName) }
        }
    }
}

/// No networks yet: the title page.
private struct Welcome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: "Keryx")
                .font(.system(size: Typeset.titleSize(Typeset.ui) * 2, weight: .light, design: .serif))
                .foregroundStyle(Palette.ink)
            Text("IRC conversations set as a script: who speaks, what they say, and in italics, what happens around them.")
                .font(Typeset.title())
                .foregroundStyle(Palette.graphite)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add a network") { model.editingNetwork = NetworkConfig() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.paper)
    }
}

/// ⌘K: jump to any conversation, or run a command.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        var id: String
        var title: String
        var detail: String
        var score: Int
        var run: () -> Void
    }

    private var items: [Item] {
        if query.hasPrefix("/") {
            let word = query.dropFirst().prefix { $0 != " " }.lowercased()
            return SlashCommand.all.filter { word.isEmpty || $0.name.hasPrefix(word) }.map { cmd in
                Item(id: cmd.name, title: cmd.usage, detail: cmd.summary, score: 0) { [model, query] in
                    guard let session = model.selectedSession, let buffer = model.selectedBuffer else { return }
                    let text = query.contains(" ") ? query : "/\(cmd.name)"
                    model.submit(text, in: buffer, of: session, replyTo: nil)
                }
            }
        }
        var out: [Item] = []
        for session in model.orderedSessions {
            for buffer in [session.statusBuffer] + model.sidebarBuffers(for: session) {
                let name = buffer.kind == .status ? session.displayName : buffer.name
                guard let score = Self.fuzzy(query, name) else { continue }
                let bonus = (buffer.hasMention ? 50 : 0) + (buffer.unreadCount > 0 ? 20 : 0)
                out.append(Item(id: buffer.id.uuidString, title: buffer.kind == .query ? model.shown(name) : name,
                                detail: buffer.kind == .status ? String(localized: "server") : session.displayName,
                                score: score + bonus) { [model] in model.select(buffer, in: session) })
            }
        }
        return out.sorted { $0.score > $1.score }.prefix(12).map { $0 }
    }

    /// Subsequence match, rewarding contiguous runs and an early start.
    static func fuzzy(_ query: String, _ text: String) -> Int? {
        guard !query.isEmpty else { return 1 }
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var qi = 0, score = 0, run = 0, first = -1
        for (ti, c) in t.enumerated() where qi < q.count {
            if c == q[qi] {
                if first < 0 { first = ti }
                run += 1
                score += 10 * run
                qi += 1
            } else {
                run = 0
            }
        }
        guard qi == q.count else { return nil }
        return score - first
    }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .onTapGesture { model.showPalette = false }
            VStack(alignment: .leading, spacing: 0) {
                TextField("Go to a conversation, or / for a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typeset.title())
                    .padding(16)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { model.showPalette = false; return .handled }
                    .onChange(of: query) { _, _ in selection = 0 }
                Rectangle().fill(Palette.rule).frame(height: 0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).font(Typeset.body())
                                Spacer()
                                Text(item.detail).font(Typeset.note()).foregroundStyle(Palette.graphite).lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(index == selection ? Palette.highlightWash.opacity(2.5) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = index; run(items) }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 560)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.rule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selection) else { return }
        items[selection].run()
        model.showPalette = false
    }
}

/// ⌘⇧F: everything ever said, across every network.
struct GlobalSearch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search all history", text: $query)
                .textFieldStyle(.plain)
                .font(Typeset.title())
                .padding(18)
                .onSubmit(search)
                .task(id: query) {
                    try? await Task.sleep(for: .milliseconds(250))
                    search()
                }
            Rectangle().fill(Palette.rule).frame(height: 0.5)
            if hits.isEmpty {
                Text(searched && !query.isEmpty ? String(localized: "Nothing matches “\(query)”.") : String(localized: "Search by words; accents and case don’t matter."))
                    .font(Typeset.direction())
                    .foregroundStyle(Palette.graphite)
                    .padding(18)
                Spacer()
            } else {
                List(hits) { hit in
                    Button {
                        model.open(hit)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(model.shown(hit.sender)).font(Typeset.speaker())
                                Text(hit.buffer).font(Typeset.note()).foregroundStyle(Palette.graphite)
                                Spacer()
                                Text(hit.time.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typeset.margin()).foregroundStyle(Palette.graphite)
                            }
                            snippet(hit.snippet)
                                .font(Typeset.body())
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            HStack {
                Text(hits.isEmpty ? "" : String(localized: "\(hits.count) results")).font(Typeset.note()).foregroundStyle(Palette.graphite)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .background(Palette.paper)
    }

    private func search() {
        let q = query
        Task {
            let found = await model.searchIndex.search(q)
            guard q == query else { return }
            hits = found
            searched = true
        }
    }

    /// The index marks matches with \u{2}…\u{3}; they become blue-pencil.
    private func snippet(_ raw: String) -> Text {
        var result = Text("")
        var rest = Substring(raw)
        while let start = rest.firstIndex(of: "\u{2}") {
            result = result + Text(String(rest[..<start]))
            let after = rest[rest.index(after: start)...]
            let end = after.firstIndex(of: "\u{3}") ?? after.endIndex
            result = result + Text(String(after[..<end])).foregroundStyle(Palette.bluePencil)
            rest = end < after.endIndex ? after[after.index(after: end)...] : ""
        }
        return result + Text(String(rest))
    }
}

/// ⌘⇧M: every line that named you, on every network, newest first.
struct MentionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let mentions = model.mentions
        let networks = Set(mentions.map(\.session.id)).count
        VStack(alignment: .leading, spacing: 0) {
            Text("Mentions")
                .font(Typeset.title())
                .padding(18)
            Rectangle().fill(Palette.rule).frame(height: 0.5)
            if mentions.isEmpty {
                Text("Nobody has mentioned you in the history Keryx has loaded.")
                    .font(Typeset.direction())
                    .foregroundStyle(Palette.graphite)
                    .padding(18)
                Spacer()
            } else {
                List(mentions) { mention in
                    Button {
                        model.open(mention)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(model.shown(mention.line.sender ?? "")).font(Typeset.speaker())
                                Text(place(of: mention, showNetwork: networks > 1))
                                    .font(Typeset.note()).foregroundStyle(Palette.graphite)
                                Spacer()
                                Text(mention.line.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typeset.margin()).foregroundStyle(Palette.graphite)
                            }
                            Text(MessageFormatter.format(model.masked(mention.line.text, in: mention.buffer, of: mention.session),
                                                         size: model.preferences.bodySize).text)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            HStack {
                Text(mentions.isEmpty ? "" : String(localized: "\(mentions.count) mentions"))
                    .font(Typeset.note()).foregroundStyle(Palette.graphite)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .background(Palette.paper)
    }

    private func place(of mention: AppModel.Mention, showNetwork: Bool) -> String {
        let name = mention.buffer.kind == .query ? model.shown(mention.buffer.name) : mention.buffer.name
        return showNetwork ? "\(name) · \(mention.session.displayName)" : name
    }
}

struct ProtocolLogView: View {
    @Environment(\.dismiss) private var dismiss
    let log: ProtocolLog
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Protocol of \(title)").font(Typeset.body())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(log.entries) { entry in
                        Text(verbatim: "\(entry.outgoing ? "→" : "←") \(entry.line)")
                            .font(Typeset.code())
                            .foregroundStyle(entry.outgoing ? Palette.bluePencil : Palette.ink)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(width: 760, height: 520)
        .background(Palette.paper)
    }
}
