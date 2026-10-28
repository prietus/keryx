import SwiftUI

/// A message body ready to set: styled text plus the links it cites.
struct FormattedMessage {
    var text: AttributedString
    var links: [URL]
}

/// Turns IRC text into typeset text. Bold, italic, underline, strikethrough
/// and monospace codes are honoured; mIRC colours are dropped on purpose, as
/// a script has one ink. Links are set in blue pencil.
enum MessageFormatter {
    private struct Style: Equatable {
        var bold = false, italic = false, underline = false, strike = false, mono = false
    }

    static func plain(_ raw: String) -> String {
        segments(raw).map(\.0).joined()
    }

    private static func segments(_ raw: String) -> [(String, Style)] {
        var out: [(String, Style)] = []
        var style = Style()
        var current = ""
        var chars = Array(raw)[...]
        func flush() {
            if !current.isEmpty { out.append((current, style)) }
            current = ""
        }
        while let c = chars.popFirst() {
            switch c {
            case "\u{02}": flush(); style.bold.toggle()
            case "\u{1D}": flush(); style.italic.toggle()
            case "\u{1F}": flush(); style.underline.toggle()
            case "\u{1E}": flush(); style.strike.toggle()
            case "\u{11}": flush(); style.mono.toggle()
            case "\u{16}": flush()  // reverse: meaningless on paper
            case "\u{0F}": flush(); style = Style()
            case "\u{03}":
                // \x03[fg[,bg]] — up to two digits each; skip them.
                flush()
                var digits = 0
                while digits < 2, let d = chars.first, d.isASCII, d.isNumber { chars.removeFirst(); digits += 1 }
                if digits > 0, chars.first == ",", chars.dropFirst().first?.isNumber == true {
                    chars.removeFirst()
                    var bg = 0
                    while bg < 2, let d = chars.first, d.isASCII, d.isNumber { chars.removeFirst(); bg += 1 }
                }
            case "\u{04}":
                // \x04RRGGBB[,RRGGBB]
                flush()
                var n = 0
                while n < 6, let d = chars.first, d.isHexDigit { chars.removeFirst(); n += 1 }
                if chars.first == "," {
                    chars.removeFirst()
                    n = 0
                    while n < 6, let d = chars.first, d.isHexDigit { chars.removeFirst(); n += 1 }
                }
            default:
                current.append(c)
            }
        }
        flush()
        return out
    }

    static func format(_ raw: String, size: CGFloat, highlight: String? = nil) -> FormattedMessage {
        var text = AttributedString()
        for (piece, style) in segments(raw) {
            var run = AttributedString(piece)
            var font: Font = style.mono
                ? .system(size: size - 1, design: .monospaced)
                : .system(size: size, weight: style.bold ? .semibold : .regular, design: Typeset.design)
            if style.italic { font = font.italic() }
            run.font = font
            if style.underline { run.underlineStyle = .single }
            if style.strike { run.strikethroughStyle = .single }
            text += run
        }
        let plain = String(text.characters)
        let found = MessageLinks.detect(in: plain)
        for match in found {
            let start = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = text.characters.index(text.startIndex, offsetBy: start)
            let upper = text.characters.index(lower, offsetBy: length)
            text[lower..<upper].link = match.url
            text[lower..<upper].foregroundColor = Palette.bluePencil
        }
        let links = found.map(\.url)
        if let highlight, !highlight.isEmpty {
            var search = text.startIndex..<text.endIndex
            while let range = text[search].range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].backgroundColor = Palette.bluePencil.opacity(0.18)
                search = range.upperBound..<text.endIndex
            }
        }
        return FormattedMessage(text: text, links: links)
    }
}
