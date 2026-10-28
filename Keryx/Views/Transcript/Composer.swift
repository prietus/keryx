import SwiftUI
import UniformTypeIdentifiers

/// The next line of the script, waiting for you: your name is already set,
/// and what you write stays in pencil until it's delivered.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let buffer: Buffer
    @Binding var replyTo: ChatLine?
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var completion: Completion?
    @State private var uploading: String?
    @State private var uploadError: String?
    @State private var importing = false

    private struct Completion {
        var stem: String
        var candidates: [String]
        var index: Int
        var base: String
        var atStart: Bool
    }

    private var size: CGFloat { model.preferences.bodySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(Palette.rule).frame(height: 0.5)
            if let replyTo {
                MarginRow(time: nil) {
                    HStack(spacing: 8) {
                        (Text("↳ replying to ") + Text(verbatim: model.shown(replyTo.sender ?? "")).font(Typeset.noteStrong(size))
                            + Text("quote.inline \(String(MessageFormatter.plain(replyTo.text).prefix(70)))"))
                            .font(Typeset.noteItalic(size))
                            .foregroundStyle(Palette.bluePencil)
                            .lineLimit(1)
                        Button { self.replyTo = nil } label: { Image(systemName: "xmark").font(Chrome.smallStrong) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.graphite)
                            .help("Cancel reply (Esc)")
                    }
                }
            }
            if let hint = commandHint {
                MarginRow(time: nil) {
                    Text(hint).font(Typeset.note(size)).foregroundStyle(Palette.graphite).lineLimit(2)
                }
            }
            if let uploading {
                MarginRow(time: nil) {
                    Text("Uploading \(uploading)…").font(Typeset.noteItalic(size)).foregroundStyle(Palette.graphite)
                }
            }
            if let uploadError {
                MarginRow(time: nil) {
                    Text(uploadError).font(Typeset.noteItalic(size)).foregroundStyle(Palette.redPencil)
                }
            }
            MarginRow(time: nil, speaker: model.shown(session.currentNick), speakerColor: Palette.graphite) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Typeset.body(size))
                        .foregroundStyle(Palette.graphite)
                        .lineLimit(1...10)
                        .focused($focused)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                                text += "\n"
                                return .handled
                            }
                            submit()
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            complete()
                            return .handled
                        }
                        .onKeyPress(.upArrow) { recall(-1) ? .handled : .ignored }
                        .onKeyPress(.downArrow) { recall(1) ? .handled : .ignored }
                        .onKeyPress(.escape) {
                            if replyTo != nil { replyTo = nil; return .handled }
                            return .ignored
                        }
                        .onChange(of: text) { _, new in
                            if completion.map({ new != $0.base + $0.candidates[$0.index] + ($0.atStart ? ": " : " ") }) ?? false {
                                completion = nil
                            }
                            session.notifyTyping(in: buffer, hasText: !new.isEmpty && !new.hasPrefix("/"),
                                                 enabled: model.preferences.sendTyping)
                        }
                    Button { importing = true } label: {
                        Image(systemName: "paperclip").font(Chrome.row)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.graphite)
                    .help(uploadHelp)
                    .padding(.leading, 8)
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 12)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { upload(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in upload(url) }
                }
            }
            return true
        }
        .onChange(of: buffer.id) { _, _ in
            completion = nil
            historyIndex = nil
        }
    }

    /// Says where the file will go, so the choice isn't a mystery.
    private var uploadHelp: String {
        switch session.uploadDestination(model.preferences) {
        case let .server(host)?:
            return String(localized: "Attach a file: uploads to this network’s file server (\(host.url.host() ?? host.url.absoluteString))")
        case let .custom(custom)?:
            return String(localized: "Attach a file: uploads to \(custom.url.host() ?? custom.url.absoluteString)")
        case nil:
            return String(localized: "Attach a file: no upload destination. This network offers no file server; set one up in Settings → Files.")
        }
    }

    private var placeholder: String {
        switch buffer.kind {
        case .status: return String(localized: "Commands for \(session.displayName)… (/join #channel)")
        case .channel: return String(localized: "Write in \(buffer.name)")
        case .query: return String(localized: "Write to \(model.shown(buffer.name))")
        }
    }

    /// Typing a command: its usage, so nobody has to remember the syntax.
    private var commandHint: String? {
        guard text.hasPrefix("/"), !text.hasPrefix("//") else { return nil }
        let word = text.dropFirst().prefix { $0 != " " }.lowercased()
        let matches = SlashCommand.all.filter { $0.name.hasPrefix(word) }
        if let exact = matches.first(where: { $0.name == word }) { return "\(exact.usage)   \(exact.summary)" }
        guard !matches.isEmpty, !text.contains(" ") else { return nil }
        return matches.prefix(8).map { "/\($0.name)" }.joined(separator: "   ")
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .newlines)
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.submit(body, in: buffer, of: session, replyTo: replyTo?.msgid)
        history.append(body)
        if history.count > 100 { history.removeFirst() }
        historyIndex = nil
        text = ""
        replyTo = nil
        uploadError = nil
    }

    /// ↑/↓ walk what you've sent, only while the field holds history (or nothing).
    private func recall(_ step: Int) -> Bool {
        guard !history.isEmpty, text.isEmpty || historyIndex != nil, !text.contains("\n") else { return false }
        let next = (historyIndex ?? history.count) + step
        if next >= history.count {
            historyIndex = nil
            text = ""
        } else {
            historyIndex = max(0, next)
            text = history[historyIndex!]
        }
        return true
    }

    /// Tab completes the last word: commands, channels, then nicks — recent
    /// speakers first — and cycles on repeat.
    private func complete() {
        if var current = completion {
            current.index = (current.index + 1) % current.candidates.count
            completion = current
            text = current.base + current.candidates[current.index] + (current.atStart ? ": " : " ")
            return
        }
        let base = String(text[..<(text.lastIndex(of: " ").map { text.index(after: $0) } ?? text.startIndex)])
        let stem = String(text[base.endIndex...])
        guard !stem.isEmpty else { return }
        var candidates: [String]
        let atStart = base.isEmpty
        if stem.hasPrefix("/"), atStart {
            candidates = SlashCommand.all.map { "/" + $0.name }.filter { $0.hasPrefix(stem.lowercased()) }
            if let only = candidates.first, candidates.count == 1 {
                text = only + " "
                return
            }
        } else if let first = stem.first, session.isupport.channelTypes.contains(first) {
            candidates = session.buffers.filter { $0.kind == .channel }.map(\.name)
                .filter { $0.lowercased().hasPrefix(stem.lowercased()) }
        } else {
            let recent = buffer.lines.suffix(300).reversed().compactMap(\.sender)
            var seen = Set<String>()
            let ordered = (recent + buffer.sortedMembers.map(\.nick) + (buffer.kind == .query ? [buffer.name] : []))
                .filter { !session.equal($0, session.currentNick) && seen.insert($0.lowercased()).inserted }
            candidates = ordered.filter { $0.lowercased().hasPrefix(stem.lowercased()) }
        }
        guard !candidates.isEmpty else { return }
        let isCommand = stem.hasPrefix("/")
        let state = Completion(stem: stem, candidates: candidates, index: 0, base: base,
                               atStart: atStart && !isCommand && !(stem.first.map { session.isupport.channelTypes.contains($0) } ?? false))
        completion = state
        text = base + candidates[0] + (state.atStart ? ": " : " ")
    }

    private func upload(_ url: URL) {
        guard let destination = session.uploadDestination(model.preferences) else {
            uploadError = UploadError.noDestination.localizedDescription
            return
        }
        uploading = url.lastPathComponent
        uploadError = nil
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let link = try await Uploader.upload(fileAt: url, to: destination)
                text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + link
                focused = true
            } catch {
                uploadError = error.localizedDescription
            }
            uploading = nil
        }
    }
}
