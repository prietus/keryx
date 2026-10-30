import SwiftUI
import KeryxProtocol

/// A line of dialogue: the speaker in their column, what they said in the text column.
struct SpeechRow: View {
    @Environment(AppModel.self) private var model
    let line: ChatLine
    let continued: Bool
    /// Set under its original: "↳ nick: text", with no quote.
    var nested = false
    let session: Session
    let buffer: Buffer
    let find: String?
    @Binding var replyTo: ChatLine?
    let onReact: (ChatLine) -> Void

    @State private var hovering = false

    private var size: CGFloat { model.preferences.bodySize }
    private var dimmed: Bool { line.sender.map(session.isDimmed) ?? false }

    private var speakerColor: Color {
        if line.mentionsMe { return Palette.bluePencil }
        return model.color(for: line.sender ?? "", isSelf: line.isSelf)
    }

    /// "↳ nick: " in front of a nested answer.
    private var threadLead: Text {
        guard nested else { return Text(verbatim: "") }
        return Text(verbatim: "↳ ").foregroundStyle(Palette.graphite)
            + Text(verbatim: model.shown(line.sender ?? "")).font(Typeset.speaker(size)).foregroundStyle(speakerColor)
            + Text(verbatim: ": ").foregroundStyle(Palette.graphite)
    }

    var body: some View {
        let formatted = MessageFormatter.format(model.masked(line.text, in: buffer, of: session), size: size, highlight: find)
        MarginRow(time: line.timestamp,
                  speaker: continued || nested ? nil : line.sender.map(model.shown),
                  speakerColor: speakerColor, speakerItalic: line.kind == .notice) {
            VStack(alignment: .leading, spacing: 1) {
                if !nested, let parent = line.replyTo {
                    ReplyQuote(msgid: parent, session: session, buffer: buffer)
                }
                if line.redacted {
                    Text(line.redactedBy.map { String(localized: "Line withdrawn by \(model.shown($0)).") }
                         ?? String(localized: "Line withdrawn."))
                        .font(Typeset.direction(size))
                        .foregroundStyle(Palette.graphite)
                } else {
                    (threadLead + Text(formatted.text))
                        .font(Typeset.body(size))
                        .foregroundStyle(line.isPending ? Palette.graphite : Palette.ink)
                        .animation(.easeOut(duration: 0.7), value: line.isPending)
                        .textSelection(.enabled)
                    if !formatted.links.isEmpty {
                        LinkPreviews(links: formatted.links)
                    }
                }
                if !line.reactions.isEmpty {
                    Reactions(line: line, session: session, buffer: buffer)
                }
            }
            .overlay(alignment: .leading) {
                // The editor's blue stroke in the margin: this one is for you.
                if line.mentionsMe {
                    Rectangle().fill(Palette.bluePencil).frame(width: 2).offset(x: -(Gutter.gap / 2) - 1)
                }
            }
        }
        .padding(.top, continued ? 0 : 2)
        .opacity(dimmed && !line.mentionsMe ? 0.35 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering, !line.redacted, line.kind != .error {
                LineActions(line: line, session: session, buffer: buffer, replyTo: $replyTo, onReact: onReact)
                    .offset(y: -2)
            }
        }
        .contextMenu { LineMenu(line: line, session: session, buffer: buffer, replyTo: $replyTo, onReact: onReact) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(line.sender ?? ""): \(MessageFormatter.plain(line.text))"))
    }
}

/// `/me`: the speaker in their column, the action in italics.
struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let line: ChatLine
    let session: Session
    let buffer: Buffer
    @Binding var replyTo: ChatLine?
    let onReact: (ChatLine) -> Void

    var body: some View {
        let size = model.preferences.bodySize
        MarginRow(time: line.timestamp, speaker: line.sender.map(model.shown),
                  speakerColor: model.color(for: line.sender ?? "", isSelf: line.isSelf), speakerItalic: true) {
            VStack(alignment: .leading, spacing: 1) {
                Text(MessageFormatter.format(model.masked(line.text, in: buffer, of: session), size: size).text)
                    .font(Typeset.direction(size))
                    .foregroundStyle(line.isPending ? Palette.graphite : Palette.ink)
                    .animation(.easeOut(duration: 0.7), value: line.isPending)
                    .textSelection(.enabled)
                if !line.reactions.isEmpty {
                    Reactions(line: line, session: session, buffer: buffer)
                }
            }
        }
        .padding(.top, 2)
        .contextMenu { LineMenu(line: line, session: session, buffer: buffer, replyTo: $replyTo, onReact: onReact) }
    }
}

/// "↳ to teraflops: “…”" — the line being answered, quoted small.
private struct ReplyQuote: View {
    @Environment(AppModel.self) private var model
    let msgid: String
    let session: Session
    let buffer: Buffer

    var body: some View {
        Button {
            session.showOriginal(of: msgid, in: buffer)
        } label: {
            Group {
                if let parent = buffer.line(withMsgID: msgid) {
                    Text("↳ to ") + Text(verbatim: model.shown(parent.sender ?? "")).font(Typeset.noteStrong(model.preferences.bodySize))
                        .foregroundStyle(model.color(for: parent.sender ?? "", isSelf: parent.isSelf))
                        + Text("quote.inline \(String(MessageFormatter.plain(model.masked(parent.text, in: buffer, of: session)).prefix(90)) + (parent.text.count > 90 ? "…" : ""))")
                } else {
                    Text("↳ in reply to an earlier message")
                }
            }
            .font(Typeset.noteItalic(model.preferences.bodySize))
            .foregroundStyle(Palette.graphite)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Go to the original message")
    }
}

/// Under a line with links: images as plates (up to three), and one quiet
/// line with the title of the first page that has one. Nothing else.
private struct LinkPreviews: View {
    @Environment(AppModel.self) private var model
    let links: [URL]
    @State private var infos: [URL: LinkInfo] = [:]

    var body: some View {
        let images = links.compactMap { url -> URL? in
            guard let info = infos[url] else { return nil }
            return info.kind == .image ? info.url : info.imageURL
        }
        let videos = links.compactMap { infos[$0]?.kind == .video ? infos[$0]?.url : nil }
        let page = links.lazy.compactMap { infos[$0] }.first {
            $0.kind == .page && $0.imageURL == nil && !($0.title ?? "").isEmpty
        }
        VStack(alignment: .leading, spacing: 2) {
            if model.preferences.inlineImages {
                ForEach(images.prefix(3), id: \.self) { Plate(url: $0) }
                ForEach(videos.prefix(2), id: \.self) { VideoPlate(url: $0) }
            }
            if model.preferences.linkFootnotes, let page, page.title != nil {
                LinkCard(info: page)
            }
        }
        .task(id: links) {
            await LinkResolver.shared.setWrapperHosts(model.wrapperHosts)
            for url in links.prefix(4) where infos[url] == nil {
                infos[url] = await LinkResolver.shared.resolve(url)
            }
        }
    }
}

/// A page's preview, like irkt's: title, a two-line summary and the site,
/// with the page's own picture small beside it. Set off by a hairline on the
/// left rather than boxed, so it reads as an aside to the line above.
private struct LinkCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let info: LinkInfo
    @State private var thumbnail: NSImage?

    var body: some View {
        let size = model.preferences.bodySize
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Palette.rule).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: info.site ?? info.url.host() ?? "")
                    .font(Typeset.note(size))
                    .foregroundStyle(Palette.graphite)
                    .lineLimit(1)
                Text(verbatim: info.title ?? "")
                    .font(Typeset.speaker(size))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if let summary = info.summary, !model.preferences.compactPreviews {
                    Text(verbatim: summary)
                        .font(Typeset.note(size))
                        .foregroundStyle(Palette.graphite)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            if let thumbnail, model.preferences.inlineImages {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: info.isVideoPage ? 128 : 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay { if info.isVideoPage { PlayBadge(duration: info.duration).scaleEffect(0.8) } }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { openURL(info.url) }
        .help(info.url.absoluteString)
        .task(id: info.thumbnail) {
            if let url = info.thumbnail { thumbnail = await ImageCache.shared.image(for: url) }
        }
    }
}

/// An image set in the column as a thumbnail: never larger than the
/// chosen height, never scaled up past its own size. Click to see it
/// large; ⌘-click opens it in the browser.
private struct Plate: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false
    @State private var enlarged = false
    @State private var hovering = false

    /// GIFs play unless you've asked for less motion; then on hover.
    private var animates: Bool {
        (model.preferences.animateGIFs && !Motion.reduced) || hovering
    }

    var body: some View {
        let maxHeight = CGFloat(model.preferences.imageSize)
        Group {
            if let image {
                let size = Self.fit(image.size, maxWidth: maxHeight * 1.8, maxHeight: maxHeight)
                Group {
                    if image.isAnimated {
                        AnimatedImage(image: image, animates: animates)
                    } else {
                        Image(nsImage: image).resizable().interpolation(.high)
                    }
                }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) { openURL(url) } else { enlarged = true }
                    }
                    .help(url.absoluteString)
                    .popover(isPresented: $enlarged, arrowEdge: .trailing) {
                        let big = Self.fit(image.size, maxWidth: 900, maxHeight: 700)
                        Group {
                            if image.isAnimated { AnimatedImage(image: image, animates: true) }
                            else { Image(nsImage: image).resizable().interpolation(.high) }
                        }
                            .frame(width: big.width, height: big.height)
                            .padding(6)
                    }
            } else if !failed {
                RoundedRectangle(cornerRadius: 3).fill(Palette.rule.opacity(0.4))
                    .frame(width: maxHeight * 1.3, height: maxHeight * 0.7)
            }
        }
        .padding(.vertical, 2)
        .task(id: url) {
            image = await ImageCache.shared.image(for: url)
            failed = image == nil
        }
    }

    /// `natural` scaled down to fit the box, never up.
    static func fit(_ natural: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let scale = min(1, maxWidth / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }
}

/// Reactions, written in the margin of the line like an editor's tally.
private struct Reactions: View {
    @Environment(AppModel.self) private var model
    let line: ChatLine
    let session: Session
    let buffer: Buffer

    var body: some View {
        HStack(spacing: 14) {
            ForEach(line.reactions.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) },
                    id: \.key) { emoji, nicks in
                let mine = nicks.contains { session.equal($0, session.currentNick) }
                Button {
                    session.toggleReaction(emoji, to: line, in: buffer)
                } label: {
                    HStack(spacing: 3) {
                        Text(emoji).font(Typeset.note(model.preferences.bodySize))
                        if nicks.count > 1 {
                            Text("\(nicks.count)").font(Typeset.margin(model.preferences.bodySize))
                        }
                    }
                    .foregroundStyle(mine ? Palette.bluePencil : Palette.graphite)
                    .padding(.bottom, 1)
                    .overlay(alignment: .bottom) {
                        if mine { Rectangle().fill(Palette.bluePencil).frame(height: 1) }
                    }
                }
                .buttonStyle(.plain)
                .help(StageWriter.list(nicks.sorted().map(model.shown), limit: 8))
            }
        }
    }
}

/// The few things you can do with a line, on hover.
private struct LineActions: View {
    let line: ChatLine
    let session: Session
    let buffer: Buffer
    @Binding var replyTo: ChatLine?
    let onReact: (ChatLine) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if line.msgid != nil {
                action("arrowshape.turn.up.left", String(localized: "Reply")) { replyTo = line }
                if session.networkAllowsReactions {
                    action("face.smiling", String(localized: "React")) { onReact(line) }
                }
            }
            action("doc.on.doc", String(localized: "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MessageFormatter.plain(line.text), forType: .string)
            }
        }
        .padding(3)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.rule, lineWidth: 0.5))
    }

    private func action(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(Chrome.small).frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.graphite)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct LineMenu: View {
    @Environment(AppModel.self) private var model
    let line: ChatLine
    let session: Session
    let buffer: Buffer
    @Binding var replyTo: ChatLine?
    let onReact: (ChatLine) -> Void

    var body: some View {
        if line.msgid != nil {
            Button("Reply") { replyTo = line }
            if session.networkAllowsReactions {
                Button("React…") { onReact(line) }
                Menu("Quick reaction") {
                    ForEach(["👍", "❤️", "😂", "🎉", "👀", "🙏"], id: \.self) { emoji in
                        Button(emoji) { session.toggleReaction(emoji, to: line, in: buffer) }
                    }
                }
            }
        }
        Button("Copy text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MessageFormatter.plain(line.text), forType: .string)
        }
        if let sender = line.sender, !line.isSelf {
            Divider()
            Button("Private conversation with \(sender)") {
                model.select(session.openQuery(sender), in: session)
            }
            Button("Profile of \(sender)") { session.requestWhois(sender) }
            Button(session.isDimmed(sender) ? String(localized: "Stop dimming") : String(localized: "Dim \(sender)")) {
                session.setDimmed(!session.isDimmed(sender), sender)
            }
            if let rule = session.plainIgnore(for: sender) {
                Button("Stop ignoring \(sender)") { session.unignore(rule) }
            } else if let mask = IgnoreMask(parsing: sender) {
                Button("Ignore \(sender)") { session.ignore(mask) }
            }
        }
        if line.isSelf, line.msgid != nil, session.networkAllowsRedaction, !line.redacted {
            Divider()
            Button("Withdraw this line", role: .destructive) { session.redact(line, in: buffer) }
        }
        if let msgid = line.msgid {
            Divider()
            Button("Copy msgid") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(msgid, forType: .string)
            }
        }
    }
}
