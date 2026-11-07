import SwiftUI
import AppKit

/// Keryx's palette: an editor's desk. Conversations are set in ink on a cool
/// paper; anything not yet final (your draft, a line the server hasn't
/// confirmed, someone's cue while they type) is in graphite; the editor's blue
/// pencil marks what concerns you; the red pencil marks what went wrong.
enum Palette {
    /// Page background.
    static let paper = themed(\.paper)
    /// Sidebar / inspector background, a shade off the page.
    static let board = themed(\.board)
    /// Final, confirmed text.
    static let ink = themed(\.ink)
    /// Drafts, unconfirmed lines, stage directions, metadata.
    static let graphite = themed(\.graphite)
    /// Hairlines and rules.
    static let rule = themed(\.rule)
    /// Mentions, links, your attention.
    static let bluePencil = themed(\.bluePencil)
    /// Errors and deletions.
    static let redPencil = themed(\.redPencil)
    /// The faint wash behind a line that mentions you.
    static let highlightWash = themed(\.bluePencil, alpha: 0.07)

    /// The theme chosen in Settings. Read whenever a colour is drawn; the
    /// app's appearance follows it, and views are re-identified on change.
    nonisolated(unsafe) static var theme: Theme = .automatic

    /// Twelve muted hues for nicks, spread around the wheel but skipping the
    /// blue band the blue pencil (mentions, links) owns. Neighbouring hues
    /// alternate between a soft and a deeper tone so they don't blur together.
    /// Each has a darker variant on paper and a lighter one at night.
    static let nickHues: [Color] = [350, 15, 38, 58, 85, 115, 148, 178, 270, 290, 310, 330]
        .enumerated().map { index, degrees in
            let deep = index % 2 == 1
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hue: CGFloat(degrees) / 360,
                               saturation: dark ? (deep ? 0.55 : 0.36) : (deep ? 0.8 : 0.6),
                               brightness: dark ? (deep ? 0.8 : 0.93) : (deep ? 0.45 : 0.58),
                               alpha: 1)
            })
        }

    /// A nick's colour: the same every time, whatever the case.
    static func nick(_ nick: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in nick.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return nickHues[Int(hash % UInt32(nickHues.count))]
    }

    private static func themed(_ ink: KeyPath<Theme.Inks, UInt32>, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = theme.inks(dark: dark)[keyPath: ink]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: alpha)
        })
    }
}

/// The page Keryx is set on. Automatic follows macOS between Paper and
/// Night; the others hold whatever the system does.
enum Theme: String, CaseIterable, Identifiable, Sendable {
    case automatic, paper, sepia, night, carbon

    var id: String { rawValue }

    struct Inks {
        var paper, board, ink, graphite, rule, bluePencil, redPencil: UInt32
    }

    /// nil follows the system.
    var appearance: NSAppearance.Name? {
        switch self {
        case .automatic: nil
        case .paper, .sepia: .aqua
        case .night, .carbon: .darkAqua
        }
    }

    /// Paper and Night sit well with the system's translucent sidebar; the
    /// others paint it in their own board colour so the page reads as one.
    var paintsSidebar: Bool { self == .sepia || self == .carbon }

    func inks(dark: Bool) -> Inks {
        switch self {
        case .automatic: dark ? Self.night.inks(dark: true) : Self.paper.inks(dark: false)
        // A cool paper, ink nearly black.
        case .paper: Inks(paper: 0xF3F4F1, board: 0xE8EAE5, ink: 0x1C1D22, graphite: 0x6C6F77,
                          rule: 0xD3D5CF, bluePencil: 0x2B50C8, redPencil: 0xB8332C)
        // Old book paper, brown ink: easier on the eyes for long reading.
        case .sepia: Inks(paper: 0xF4ECDB, board: 0xEADFC8, ink: 0x3A2F25, graphite: 0x86765F,
                          rule: 0xDACCB0, bluePencil: 0x2C5A9C, redPencil: 0xA63D2A)
        // The desk at night: blue-grey, ink like chalk.
        case .night: Inks(paper: 0x15171C, board: 0x1B1E24, ink: 0xE6E4DE, graphite: 0x8E919A,
                          rule: 0x2B2E36, bluePencil: 0x7D9BFF, redPencil: 0xFF7D70)
        // True black for OLED and dark rooms, a touch more contrast.
        case .carbon: Inks(paper: 0x000000, board: 0x0B0B0D, ink: 0xF2F2F0, graphite: 0x9C9CA4,
                           rule: 0x26262C, bluePencil: 0x8FAEFF, redPencil: 0xFF8A7A)
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .night: "Night"
        case .carbon: "Carbon"
        }
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
