import SwiftUI
import AppKit

/// Keryx's palette: an editor's desk. Conversations are set in ink on a cool
/// paper; anything not yet final (your draft, a line the server hasn't
/// confirmed, someone's cue while they type) is in graphite; the editor's blue
/// pencil marks what concerns you; the red pencil marks what went wrong.
enum Palette {
    /// Page background.
    static let paper = dynamic(light: 0xF3F4F1, dark: 0x15171C)
    /// Sidebar / inspector background, a shade off the page.
    static let board = dynamic(light: 0xE8EAE5, dark: 0x1B1E24)
    /// Final, confirmed text.
    static let ink = dynamic(light: 0x1C1D22, dark: 0xE6E4DE)
    /// Drafts, unconfirmed lines, stage directions, metadata.
    static let graphite = dynamic(light: 0x6C6F77, dark: 0x8E919A)
    /// Hairlines and rules.
    static let rule = dynamic(light: 0xD3D5CF, dark: 0x2B2E36)
    /// Mentions, links, your attention.
    static let bluePencil = dynamic(light: 0x2B50C8, dark: 0x7D9BFF)
    /// Errors and deletions.
    static let redPencil = dynamic(light: 0xB8332C, dark: 0xFF7D70)
    /// The faint wash behind a line that mentions you.
    static let highlightWash = dynamic(light: 0x2B50C8, dark: 0x7D9BFF, alpha: 0.07)

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: alpha)
        })
    }
}

/// The type scale: three sizes, all derived from the body size the reader
/// picks, and one family throughout (SF by default, New York if chosen in
/// Settings). Title for the topic and sheet headings, body for what people
/// say, note for everything around it (times, joins, link titles, labels).
enum Typeset {
    /// Body size outside the transcript (sheets, palette, search).
    static let ui: CGFloat = 14
    /// The family, from Preferences. Read on every render; views that depend
    /// on it are re-identified when it changes.
    nonisolated(unsafe) static var design: Font.Design = .default

    static func titleSize(_ body: CGFloat) -> CGFloat { body + 3 }
    static func noteSize(_ body: CGFloat) -> CGFloat { body - 2 }

    static func title(_ body: CGFloat = ui) -> Font { .system(size: titleSize(body), weight: .medium, design: design) }
    static func body(_ body: CGFloat = ui) -> Font { .system(size: body, design: design) }
    static func speaker(_ body: CGFloat = ui) -> Font { .system(size: body, weight: .semibold, design: design) }
    static func direction(_ body: CGFloat = ui) -> Font { .system(size: body, design: design).italic() }
    static func note(_ body: CGFloat = ui) -> Font { .system(size: noteSize(body), design: design) }
    static func noteItalic(_ body: CGFloat = ui) -> Font { .system(size: noteSize(body), design: design).italic() }
    static func noteStrong(_ body: CGFloat = ui) -> Font { .system(size: noteSize(body), weight: .semibold, design: design) }
    static func margin(_ body: CGFloat = ui) -> Font { .system(size: noteSize(body)).monospacedDigit() }
    static func code(_ body: CGFloat = ui) -> Font { .system(size: noteSize(body), design: .monospaced) }
}

/// The two sizes of the sidebar and inspector (SF).
enum Chrome {
    static let row = Font.system(size: 13)
    static let rowStrong = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11)
    static let smallStrong = Font.system(size: 11, weight: .semibold)
}
