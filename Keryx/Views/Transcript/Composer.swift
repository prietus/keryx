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
    /// Bumped by the conversation to put the caret here.
    @Binding var focusToken: Int

    @State private var history: [String] = []
    @State private var historyIndex: Int?
    /// While Tab cycles: the completion and which candidate is in the text.
    @State private var cycling: (result: CompletionEngine.Result, index: Int)?
    @State private var uploading: String?
    @State private var uploadError: String?
    @State private var importing = false
    @State private var fieldHeight: CGFloat = 18

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
                    ComposerTextView(
                        text: $text, placeholder: placeholder, font: nsFont, color: NSColor(Palette.graphite),
                        ghost: cycling == nil ? suggestion?.ghost : nil,
                        language: session.spellingLanguage(for: buffer.name),
                        focusToken: focusToken, height: $fieldHeight,
                        onSubmit: submit,
                        onTab: complete,
                        onAcceptGhost: acceptGhost,
                        onHistory: recall,
                        onEscape: {
                            if replyTo != nil { replyTo = nil; return true }
                            return false
                        },
                        onFiles: { $0.forEach(upload) })
                        .frame(height: fieldHeight)
                        .alignmentGuide(.firstTextBaseline) { _ in nsFont.ascender }
                        .onChange(of: text) { _, new in
                            if let current = cycling, new != current.result.text(accepting: current.index) {
                                cycling = nil
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
            cycling = nil
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

    private var nsFont: NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard model.preferences.serifType, let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: serif, size: size) ?? base
    }

    /// What the last word could become: commands, channels, nicks (recent
    /// speakers first), then dictionary words in the conversation's language.
    private var completionContext: CompletionContext {
        let recent = buffer.lines.suffix(300).reversed().compactMap(\.sender)
        var seen = Set<String>()
        let nicks = (recent + buffer.sortedMembers.map(\.nick) + (buffer.kind == .query ? [buffer.name] : []))
            .filter { !session.equal($0, session.currentNick) && seen.insert($0.lowercased()).inserted }
        let language = session.spellingLanguage(for: buffer.name)
        return CompletionContext(
            commands: SlashCommand.all.map { "/" + $0.name },
            channels: session.buffers.filter { $0.kind == .channel }.map(\.name),
            nicks: nicks,
            channelTypes: session.isupport.channelTypes,
            words: { stem in
                guard language != "off" else { return [] }
                return NSSpellChecker.shared.completions(
                    forPartialWordRange: NSRange(location: 0, length: (stem as NSString).length),
                    in: stem, language: language, inSpellDocumentWithTag: 0) ?? []
            })
    }

    /// The suggestion for what's typed, shown as a ghost after the caret.
    private var suggestion: CompletionEngine.Result? {
        guard !text.isEmpty, text.last != " ", text.last != "\n" else { return nil }
        return CompletionEngine.complete(text, completionContext)
    }

    /// Tab: accept the suggestion, then cycle through the other candidates.
    private func complete() -> Bool {
        if var current = cycling {
            current.index = (current.index + 1) % current.result.candidates.count
            cycling = current
            text = current.result.text(accepting: current.index)
            return true
        }
        guard let result = suggestion else { return false }
        cycling = (result, 0)
        text = result.text(accepting: 0)
        return true
    }

    /// → at the end of the line: take the ghost, without cycling.
    private func acceptGhost() -> Bool {
        guard cycling == nil, let result = suggestion, result.ghost != nil else { return false }
        text = result.text(accepting: 0)
        return true
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
                focusToken += 1
            } catch {
                uploadError = error.localizedDescription
            }
            uploading = nil
        }
    }
}
