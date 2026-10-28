import Foundation
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
    /// Words besides your nick that mark a line as meant for you.
    var highlightWords: [String] { didSet { defaults.set(highlightWords, forKey: "highlightWords") } }
    /// Show joins/parts/quits at all (per-conversation overrides live in NetworkState).
    var showPresence: Bool { didSet { defaults.set(showPresence, forKey: "showPresence") } }
    /// Show a nick change only for people who spoke recently, not silent lurkers.
    var presenceOnlyForSpeakers: Bool { didSet { defaults.set(presenceOnlyForSpeakers, forKey: "presenceOnlyForSpeakers") } }
    var inlineImages: Bool { didSet { defaults.set(inlineImages, forKey: "inlineImages") } }
    /// Thumbnail height in points: 96, 160 or 280.
    var imageSize: Int { didSet { defaults.set(imageSize, forKey: "imageSize") } }
    /// Link titles as footnotes under the line.
    var linkFootnotes: Bool { didSet { defaults.set(linkFootnotes, forKey: "linkFootnotes") } }
    var notifyMentions: Bool { didSet { defaults.set(notifyMentions, forKey: "notifyMentions") } }
    var notifyDirect: Bool { didSet { defaults.set(notifyDirect, forKey: "notifyDirect") } }
    var sendTyping: Bool { didSet { defaults.set(sendTyping, forKey: "sendTyping") } }
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    /// Masks every nick with a stable pseudonym (screenshots, streaming).
    var privacyMode = false

    // Custom uploader (0x0-style), used when the server has no FILEHOST.
    var uploaderURL: String { didSet { defaults.set(uploaderURL, forKey: "uploaderURL") } }
    var uploaderField: String { didSet { defaults.set(uploaderField, forKey: "uploaderField") } }
    var uploaderToken: String { didSet { defaults.set(uploaderToken, forKey: "uploaderToken") } }
    /// `text` (body is the URL), `location` (header) or `json:<key.path>`.
    var uploaderResponse: String { didSet { defaults.set(uploaderResponse, forKey: "uploaderResponse") } }
    var preferServerFileHost: Bool { didSet { defaults.set(preferServerFileHost, forKey: "preferServerFileHost") } }

    /// Stable per-install client name for soju's per-client history (`user@client`).
    let clientName: String

    init() {
        defaults.register(defaults: [
            "bodySize": 13.0, "showPresence": true, "presenceOnlyForSpeakers": true,
            "inlineImages": true, "imageSize": 160, "linkFootnotes": true, "notifyMentions": true,
            "notifyDirect": true, "sendTyping": true, "keepHistory": true,
            "uploaderField": "file", "uploaderResponse": "text", "preferServerFileHost": true,
        ])
        bodySize = defaults.double(forKey: "bodySize")
        let serif = defaults.bool(forKey: "serifType")
        serifType = serif
        Typeset.design = serif ? .serif : .default
        highlightWords = defaults.stringArray(forKey: "highlightWords") ?? []
        showPresence = defaults.bool(forKey: "showPresence")
        presenceOnlyForSpeakers = defaults.bool(forKey: "presenceOnlyForSpeakers")
        inlineImages = defaults.bool(forKey: "inlineImages")
        imageSize = defaults.integer(forKey: "imageSize")
        linkFootnotes = defaults.bool(forKey: "linkFootnotes")
        notifyMentions = defaults.bool(forKey: "notifyMentions")
        notifyDirect = defaults.bool(forKey: "notifyDirect")
        sendTyping = defaults.bool(forKey: "sendTyping")
        keepHistory = defaults.bool(forKey: "keepHistory")
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
