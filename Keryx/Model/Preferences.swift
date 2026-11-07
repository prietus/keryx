import AppKit
import Observation

/// App-wide preferences, backed by UserDefaults.
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var bodySize: Double { didSet { defaults.set(bodySize, forKey: "bodySize") } }
    /// New York instead of SF for the conversation and sheets.
    var serifType: Bool {
        didSet {
            defaults.set(serifType, forKey: "serifType")
            Typeset.design = serifType ? .serif : .default
        }
    }
    var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            Palette.theme = theme
            applyAppearance()
        }
    }
    /// Words besides your nick that mark a line as meant for you.
    var highlightWords: [String] { didSet { defaults.set(highlightWords, forKey: "highlightWords") } }
    /// Show joins/parts/quits at all (per-conversation overrides live in NetworkState).
    var showPresence: Bool { didSet { defaults.set(showPresence, forKey: "showPresence") } }
    /// Show a nick change only for people who spoke recently, not silent lurkers.
    var presenceOnlyForSpeakers: Bool { didSet { defaults.set(presenceOnlyForSpeakers, forKey: "presenceOnlyForSpeakers") } }
    var inlineImages: Bool { didSet { defaults.set(inlineImages, forKey: "inlineImages") } }
    /// Animated GIFs play (still, and on hover, with Reduce Motion).
    var animateGIFs: Bool { didSet { defaults.set(animateGIFs, forKey: "animateGIFs") } }
    /// Each nick in its own colour (otherwise all in ink).
    var colorNicks: Bool { didSet { defaults.set(colorNicks, forKey: "colorNicks") } }
    /// Thumbnail height in points: 96, 160 or 280.
    var imageSize: Int { didSet { defaults.set(imageSize, forKey: "imageSize") } }
    /// Link titles as footnotes under the line.
    var linkFootnotes: Bool { didSet { defaults.set(linkFootnotes, forKey: "linkFootnotes") } }
    /// Link cards without the summary line.
    var compactPreviews: Bool { didSet { defaults.set(compactPreviews, forKey: "compactPreviews") } }
    var notifyMentions: Bool { didSet { defaults.set(notifyMentions, forKey: "notifyMentions") } }
    var notifyDirect: Bool { didSet { defaults.set(notifyDirect, forKey: "notifyDirect") } }
    var sendTyping: Bool { didSet { defaults.set(sendTyping, forKey: "sendTyping") } }
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    /// Marks you away while the screen is locked, or after a while idle.
    var autoAway: Bool { didSet { defaults.set(autoAway, forKey: "autoAway") } }
    /// Minutes without touching the Mac before auto-away; 0 is only when locked.
    var autoAwayMinutes: Int { didSet { defaults.set(autoAwayMinutes, forKey: "autoAwayMinutes") } }
    /// The reason auto-away gives; empty uses a plain "Away".
    var awayMessage: String { didSet { defaults.set(awayMessage, forKey: "awayMessage") } }
    /// Masks every nick with a stable pseudonym (screenshots, streaming).
    var privacyMode = false

    // Custom uploader (0x0-style), used when the server has no FILEHOST.
    var uploaderURL: String { didSet { defaults.set(uploaderURL, forKey: "uploaderURL") } }
    var uploaderField: String { didSet { defaults.set(uploaderField, forKey: "uploaderField") } }
    var uploaderToken: String { didSet { defaults.set(uploaderToken, forKey: "uploaderToken") } }
    /// `text` (body is the URL), `location` (header) or `json:<key.path>`.
    var uploaderResponse: String { didSet { defaults.set(uploaderResponse, forKey: "uploaderResponse") } }
    var preferServerFileHost: Bool { didSet { defaults.set(preferServerFileHost, forKey: "preferServerFileHost") } }

    /// Windows, sheets and system controls take the theme's light or dark.
    /// Preferences start before NSApplication, so RootView calls this again.
    func applyAppearance() {
        NSApp?.appearance = theme.appearance.flatMap(NSAppearance.init(named:))
    }

    /// Stable per-install client name for soju's per-client history (`user@client`).
    let clientName: String

    init() {
        defaults.register(defaults: [
            "bodySize": 13.0, "showPresence": true, "presenceOnlyForSpeakers": true,
            "inlineImages": true, "imageSize": 160, "colorNicks": true, "animateGIFs": true, "linkFootnotes": true, "notifyMentions": true,
            "notifyDirect": true, "sendTyping": true, "keepHistory": true,
            "autoAway": true, "autoAwayMinutes": 15,
            "uploaderField": "file", "uploaderResponse": "text", "preferServerFileHost": true,
        ])
        bodySize = defaults.double(forKey: "bodySize")
        let serif = defaults.bool(forKey: "serifType")
        serifType = serif
        Typeset.design = serif ? .serif : .default
        var theme = defaults.string(forKey: "theme").flatMap(Theme.init(rawValue:)) ?? .automatic
        #if DEBUG
        // Screenshots of each theme without touching your saved choice.
        if let demo = ProcessInfo.processInfo.environment["KERYX_DEMO_THEME"].flatMap(Theme.init(rawValue:)) {
            theme = demo
        }
        #endif
        self.theme = theme
        Palette.theme = theme
        highlightWords = defaults.stringArray(forKey: "highlightWords") ?? []
        showPresence = defaults.bool(forKey: "showPresence")
        presenceOnlyForSpeakers = defaults.bool(forKey: "presenceOnlyForSpeakers")
        inlineImages = defaults.bool(forKey: "inlineImages")
        imageSize = defaults.integer(forKey: "imageSize")
        colorNicks = defaults.bool(forKey: "colorNicks")
        animateGIFs = defaults.bool(forKey: "animateGIFs")
        linkFootnotes = defaults.bool(forKey: "linkFootnotes")
        compactPreviews = defaults.bool(forKey: "compactPreviews")
        notifyMentions = defaults.bool(forKey: "notifyMentions")
        notifyDirect = defaults.bool(forKey: "notifyDirect")
        sendTyping = defaults.bool(forKey: "sendTyping")
        keepHistory = defaults.bool(forKey: "keepHistory")
        autoAway = defaults.bool(forKey: "autoAway")
        autoAwayMinutes = defaults.integer(forKey: "autoAwayMinutes")
        awayMessage = defaults.string(forKey: "awayMessage") ?? ""
        uploaderURL = defaults.string(forKey: "uploaderURL") ?? ""
        uploaderField = defaults.string(forKey: "uploaderField") ?? "file"
        uploaderToken = defaults.string(forKey: "uploaderToken") ?? ""
        uploaderResponse = defaults.string(forKey: "uploaderResponse") ?? "text"
        preferServerFileHost = defaults.bool(forKey: "preferServerFileHost")
        if let name = defaults.string(forKey: "clientName") {
            clientName = name
        } else {
            let name = "keryx-" + UUID().uuidString.prefix(6).lowercased()
            defaults.set(name, forKey: "clientName")
            clientName = name
        }
    }
}
