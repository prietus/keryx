import SwiftUI
import AppKit

/// The conversation, set as a script.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let buffer: Buffer
    var find: String?
    @Binding var replyTo: ChatLine?
    var onReact: (ChatLine) -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var anchorBeforeLoad: String?
    @State private var flashedLine: UUID?

    private var rows: [TranscriptRow] {
        var options = TranscriptLayout.Options()
        options.showPresence = model.preferences.showPresence && !session.isPresenceQuiet(buffer.name)
        options.presenceOnlyForSpeakers = model.preferences.presenceOnlyForSpeakers
        options.isHidden = { [session] in session.isIgnored($0) }
        options.firstUnreadID = buffer.firstUnreadID
        var rows = TranscriptLayout.rows(for: buffer.lines, options: options)
        if let find, !find.isEmpty {
            rows = rows.filter { row in
                row.lines.contains { MessageFormatter.plain($0.text).localizedStandardContains(find)
                    || ($0.sender?.localizedStandardContains(find) ?? false) }
            }
        }
        return rows
    }

    var body: some View {
        let rows = rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if buffer.kind != .status, session.hasChathistory, find == nil {
                    HistoryEdge(buffer: buffer)
                        .onAppear(perform: loadOlder)
                }
                ForEach(rows) { row in
                    TranscriptRowView(row: row, session: session, buffer: buffer, find: find,
                                      flashed: row.lines.contains { $0.id == flashedLine },
                                      replyTo: $replyTo, onReact: onReact)
                        .id(row.id)
                }
                TypingCue(buffer: buffer)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // Images arrive after their line is laid out; keep the bottom edge put
        // as they grow, so the newest line isn't pushed under the composer.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
        } action: { _, bottom in
            atBottom = bottom
        }
        .onChange(of: buffer.lines.last?.id) { _, _ in
            guard find == nil else { return }
            if atBottom || buffer.lines.last?.isSelf == true {
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: rows.first?.id) { _, _ in
            // An older page landed above us: keep the reader where they were.
            if let anchor = anchorBeforeLoad {
                position.scrollTo(id: anchor, anchor: .top)
                anchorBeforeLoad = nil
            }
        }
        .onChange(of: session.jumpRequest) { _, request in
            guard let request, request.bufferID == buffer.id else { return }
            session.consumeJump()
            jump(to: request.lineID, in: rows)
        }
        .onAppear {
            if let request = session.jumpRequest, request.bufferID == buffer.id {
                session.consumeJump()
                jump(to: request.lineID, in: rows)
            }
        }
    }

    private func loadOlder() {
        guard !buffer.isLoadingHistory, !buffer.historyExhausted, !buffer.lines.isEmpty else { return }
        anchorBeforeLoad = rows.first { if case .day = $0 { return false } else { return true } }?.id
        session.loadMoreHistory(for: buffer)
    }

    private func jump(to lineID: UUID, in rows: [TranscriptRow]) {
        guard let row = rows.first(where: { $0.lines.contains { $0.id == lineID } }) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { position.scrollTo(id: row.id, anchor: .center) }
        flashedLine = lineID
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.6)) { flashedLine = nil }
        }
    }
}

/// The top of the loaded scrollback: either more to fetch, or the beginning.
private struct HistoryEdge: View {
    @Environment(AppModel.self) private var model
    let buffer: Buffer

    var body: some View {
        HStack {
            Spacer()
            if buffer.historyExhausted {
                Text("Beginning of the conversation")
                    .font(Typeset.noteItalic(model.preferences.bodySize))
                    .foregroundStyle(Palette.graphite)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// Someone's next line is coming: their name, set as a cue.
private struct TypingCue: View {
    let buffer: Buffer
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let typing = buffer.currentlyTyping(asOf: context.date)
            if !typing.isEmpty {
                MarginRow(time: nil, speaker: StageWriter.list(typing.map(model.shown), limit: 2),
                          speakerColor: Palette.graphite) {
                    Text(verbatim: "—")
                        .font(Typeset.body(model.preferences.bodySize))
                        .phaseAnimator([0.25, 1]) { view, phase in view.opacity(phase) } animation: { _ in
                            .easeInOut(duration: 0.8)
                        }
                }
                .foregroundStyle(Palette.graphite)
                .padding(.top, 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(StageWriter.list(typing)) is typing"))
                .transition(.opacity)
            }
        }
    }
}

extension EnvironmentValues {
    /// Width of the speaker column: the longest nick in the conversation, capped.
    @Entry var nameColumn: CGFloat = 90
}

enum Gutter {
    static let gap: CGFloat = 8
    static let measure: CGFloat = 760
    /// Room for the time: "23:58" or, in 12-hour locales, "11:58 PM".
    static let time: CGFloat = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return format.contains("a") ? 54 : 34
    }()

    /// The speaker column: wide enough for the longest of `nicks`, within limits.
    static func name(for nicks: some Sequence<String>, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let widest = nicks.reduce(CGFloat(0)) { widest, nick in
            max(widest, (nick as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(max(ceil(widest) + 2, size * 3), size * 11)
    }

    /// Where text starts, measured from the row's leading edge.
    static func lead(name: CGFloat) -> CGFloat { time + gap + name + gap }
}

// MARK: - Rows

private struct TranscriptRowView: View {
    @Environment(AppModel.self) private var model
    let row: TranscriptRow
    let session: Session
    let buffer: Buffer
    let find: String?
    let flashed: Bool
    @Binding var replyTo: ChatLine?
    let onReact: (ChatLine) -> Void

    var body: some View {
        Group {
            switch row {
            case let .day(date): DayRule(date: date)
            case let .sceneBreak(unread, mentions): SceneBreak(unread: unread, mentions: mentions)
            case let .speech(line, continued):
                SpeechRow(line: line, continued: continued, session: session, buffer: buffer, find: find,
                          replyTo: $replyTo, onReact: onReact)
            case let .reply(line):
                SpeechRow(line: line, continued: false, nested: true, session: session, buffer: buffer, find: find,
                          replyTo: $replyTo, onReact: onReact)
            case let .action(line):
                ActionRow(line: line, session: session, buffer: buffer, replyTo: $replyTo, onReact: onReact)
            case let .presence(lines):
                MarginRow(time: lines.last?.timestamp) {
                    Text(StageWriter.presence(lines.map(masked)))
                        .font(Typeset.noteItalic(model.preferences.bodySize))
                        .foregroundStyle(Palette.graphite)
                }
                .padding(.top, 1)
            case let .event(line):
                EventRow(line: line)
            case let .system(line):
                SystemRow(line: line)
            }
        }
        .background(flashed ? Palette.highlightWash.opacity(3) : .clear)
    }

    private func masked(_ line: ChatLine) -> ChatLine {
        guard model.preferences.privacyMode, let direction = line.direction else { return line }
        var copy = line
        copy.direction = direction.mapNicks(model.shown)
        return copy
    }
}

/// The three columns every row shares: time, speaker, text. Text always
/// starts on the same vertical, whoever speaks, so the eye can run down it.
struct MarginRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.nameColumn) private var nameColumn
    var time: Date?
    var showTime = true
    /// Already masked for privacy mode by the caller.
    var speaker: String?
    var speakerColor: Color = Palette.ink
    var speakerItalic = false
    @ViewBuilder var content: Content

    var body: some View {
        let size = model.preferences.bodySize
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: time.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                .font(Typeset.margin(size))
                .foregroundStyle(Palette.graphite.opacity(showTime ? 0.8 : 0))
                .lineLimit(1)
                .frame(width: Gutter.time, alignment: .trailing)
                .padding(.trailing, Gutter.gap)
            Text(verbatim: speaker ?? "")
                .font(speakerItalic ? Typeset.speaker(size).italic() : Typeset.speaker(size))
                .foregroundStyle(speakerColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: nameColumn, alignment: .trailing)
                .padding(.trailing, Gutter.gap)
                .help(speaker ?? "")
            content
                .frame(maxWidth: Gutter.measure, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

private struct DayRule: View {
    @Environment(AppModel.self) private var model
    @Environment(\.nameColumn) private var nameColumn
    let date: Date

    private var label: String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)
            .year(Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) ? .omitted : .defaultDigits))
            .sentenceCased
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Gutter.lead(name: nameColumn) - 8)
            Text(label)
                .font(Typeset.note(model.preferences.bodySize))
                .foregroundStyle(Palette.graphite)
            Rectangle().fill(Palette.rule).frame(height: 0.5)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// ⁂: the scene changes here; everything below is new to you.
private struct SceneBreak: View {
    @Environment(AppModel.self) private var model
    @Environment(\.nameColumn) private var nameColumn
    let unread: Int
    let mentions: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "⁂")
                .font(Typeset.body(model.preferences.bodySize))
                .foregroundStyle(Palette.bluePencil)
            if unread > 0 {
                Text(summary)
                    .font(Typeset.noteItalic(model.preferences.bodySize))
                    .foregroundStyle(Palette.bluePencil)
            }
        }
        .padding(.leading, Gutter.lead(name: nameColumn))
        .frame(maxWidth: Gutter.lead(name: nameColumn) + Gutter.measure, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("New messages: \(summary)"))
    }

    private var summary: String {
        let news = unread == 1 ? String(localized: "1 new message") : String(localized: "\(unread) new messages")
        switch mentions {
        case 0: return news
        case 1: return String(localized: "\(news), 1 mentions you")
        default: return String(localized: "\(news), \(mentions) mention you")
        }
    }
}

private struct EventRow: View {
    @Environment(AppModel.self) private var model
    let line: ChatLine

    var body: some View {
        MarginRow(time: line.timestamp) {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.direction.map { StageWriter.event($0.mapNicks(model.shown)) } ?? line.text)
                    .font(Typeset.noteItalic(model.preferences.bodySize))
                    .foregroundStyle(Palette.graphite)
                if case let .topic(_, text)? = line.direction, !text.isEmpty {
                    Text(MessageFormatter.format(text, size: model.preferences.bodySize).text)
                        .font(Typeset.direction(model.preferences.bodySize))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 1)
    }
}

private struct SystemRow: View {
    @Environment(AppModel.self) private var model
    let line: ChatLine

    var body: some View {
        MarginRow(time: line.timestamp, speaker: line.sender.map(model.shown), speakerColor: Palette.graphite) {
            Group {
                if line.kind == .motd {
                    Text(MessageFormatter.plain(line.text))
                        .font(Typeset.code(model.preferences.bodySize))
                } else {
                    Text(MessageFormatter.format(line.text, size: model.preferences.bodySize).text)
                }
            }
            .foregroundStyle(line.kind == .error ? Palette.redPencil : Palette.graphite)
            .textSelection(.enabled)
        }
        .padding(.top, 1)
    }
}

extension Direction {
    /// The same direction with every nick passed through `f` (privacy mode).
    func mapNicks(_ f: (String) -> String) -> Direction {
        switch self {
        case let .join(n): return .join(nick: f(n))
        case let .part(n, r): return .part(nick: f(n), reason: r)
        case let .quit(n, r): return .quit(nick: f(n), reason: r)
        case let .nick(o, n): return .nick(old: f(o), new: f(n))
        case let .kick(b, n, r): return .kick(by: f(b), nick: f(n), reason: r)
        case let .topic(b, t): return .topic(by: f(b), text: t)
        case let .mode(b, m): return .mode(by: f(b), modes: m)
        case let .invite(b, n, c): return .invite(by: f(b), nick: f(n), channel: c)
        case let .setname(n, name): return .setname(nick: f(n), name: name)
        case let .chghost(n, u, h): return .chghost(nick: f(n), user: u, host: h)
        case let .account(n, a): return .account(nick: f(n), account: a)
        case let .split(s, nicks, r): return .split(servers: s, nicks: nicks.map(f), rejoined: r)
        }
    }
}

extension String {
    /// "martes, 28 de octubre" → "Martes, 28 de octubre" (only the first letter).
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}
