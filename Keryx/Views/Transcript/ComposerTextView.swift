import SwiftUI
import AppKit

/// The composer's text field: an `NSTextView`, because SwiftUI's field can't
/// draw a ghost suggestion after the caret or check spelling as you type.
/// It grows from one line to ten, then scrolls.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var color: NSColor
    /// The grey rest of a suggested word, drawn after the caret.
    var ghost: String?
    /// `nil` checks spelling in the language macOS detects; "off" disables it.
    var language: String?
    /// Bumped to move keyboard focus here.
    var focusToken: Int
    @Binding var height: CGFloat

    var onSubmit: () -> Void
    /// Tab: complete; returns whether it did anything.
    var onTab: () -> Bool
    /// → at the very end: accept the ghost.
    var onAcceptGhost: () -> Bool
    /// ↑ (-1) / ↓ (+1): walk the history; returns whether it did.
    var onHistory: (Int) -> Bool
    var onEscape: () -> Bool
    var onFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.registerForDraggedTypes([.fileURL])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        context.coordinator.textView = textView
        apply(to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        apply(to: textView)
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure()
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    private func apply(to textView: ComposerNSTextView) {
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        textView.placeholder = placeholder
        if textView.ghost != ghost {
            textView.ghost = ghost
            textView.needsDisplay = true
        }
        let spelling = language != "off"
        if textView.isContinuousSpellCheckingEnabled != spelling {
            textView.isContinuousSpellCheckingEnabled = spelling
        }
        if textView.language != language || !textView.languageApplied {
            textView.language = language
            textView.languageApplied = true
            // The checker's language is app-wide; only the composer uses it.
            let checker = NSSpellChecker.shared
            if let language, language != "off" {
                checker.automaticallyIdentifiesLanguages = false
                checker.setLanguage(language)
            } else {
                checker.automaticallyIdentifiesLanguages = true
            }
            if spelling { textView.checkTextInDocument(nil) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var focusToken = -1

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            measure()
        }

        /// Reports the height of the text (one line at least, ten at most).
        func measure() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: parent.font)
            let used = max(layout.usedRect(for: container).height, line)
            let height = min(used, line * 10).rounded(.up)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                _ = parent.onTab()
                return true
            case #selector(NSResponder.moveRight(_:)):
                let atEnd = textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0)
                return atEnd && parent.onAcceptGhost()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onHistory(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onHistory(1)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }
    }
}

/// Draws the placeholder and the ghost suggestion, corrects the nearest
/// misspelling on ⌥S, and hands dropped files to the composer.
final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    var placeholder = ""
    var ghost: String?
    var language: String?
    var languageApplied = false

    private var spellLanguage: String? {
        guard let language, language != "off" else { return nil }
        return language
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: (textColor ?? .secondaryLabelColor).withAlphaComponent(0.45),
        ]
        if string.isEmpty {
            NSAttributedString(string: placeholder, attributes: attrs).draw(at: NSPoint(x: 0, y: 0))
            return
        }
        // The ghost only makes sense with the caret at the very end.
        guard let ghost, !ghost.isEmpty, let layout = layoutManager, let container = textContainer,
              selectedRange() == NSRange(location: (string as NSString).length, length: 0) else { return }
        let end = (string as NSString).length
        let glyph = layout.glyphIndexForCharacter(at: max(end - 1, 0))
        let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let charRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let origin = NSPoint(x: charRect.maxX + textContainerOrigin.x, y: lineRect.minY + textContainerOrigin.y)
        NSAttributedString(string: ghost, attributes: attrs).draw(at: origin)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // ⌥S: replace the misspelt word nearest the caret with the top guess.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            correctNearestMisspelling()
            return
        }
        super.keyDown(with: event)
    }

    private func correctNearestMisspelling() {
        let checker = NSSpellChecker.shared
        let text = string as NSString
        let caret = selectedRange().location
        var best: NSRange?
        var start = 0
        while start < text.length {
            let range = checker.checkSpelling(of: string, startingAt: start, language: spellLanguage, wrap: false,
                                              inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            if best.map({ abs($0.location - caret) > abs(range.location - caret) }) ?? true { best = range }
            start = NSMaxRange(range)
        }
        guard let range = best,
              let guess = checker.guesses(forWordRange: range, in: string, language: spellLanguage,
                                          inSpellDocumentWithTag: spellCheckerDocumentTag)?.first else {
            NSSound.beep()
            return
        }
        if shouldChangeText(in: range, replacementString: guess) {
            replaceCharacters(in: range, with: guess)
            didChangeText()
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        coordinator?.parent.onFiles(urls)
        return true
    }
}
