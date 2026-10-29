import AppKit

/// What you're listening to or watching, for `/np`.
///
/// macOS has no public, system-wide answer (the menu bar's Now Playing reads a
/// private service that third-party apps can't query since macOS 15.4), so
/// Keryx asks the players directly, through public channels only:
///
/// 1. Any player that speaks the Keryx Now Playing protocol (see below), such
///    as Zplayer: answers a distributed-notification request.
/// 2. Music and Spotify, through AppleScript — only if they're already open;
///    Keryx never launches them.
///
/// ## The protocol
///
/// A player posts the distributed notification `im.keryx.NowPlaying` whenever
/// its track or play state changes, and again whenever it sees
/// `im.keryx.NowPlaying.request`. The payload is a JSON string in the
/// notification's `object` (sandboxed apps can't send `userInfo`):
///
///     {"player": "Zplayer", "title": "…", "artist": "…", "album": "…",
///      "playing": true, "video": false}
///
/// No `title` means nothing is playing in that player.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    static let announcement = Notification.Name("im.keryx.NowPlaying")
    static let request = Notification.Name("im.keryx.NowPlaying.request")

    struct Track: Sendable, Equatable, Decodable {
        var title: String
        var artist: String?
        var album: String?
        var isVideo = false
        var isPlaying = true
        /// The app playing it, e.g. "Music" or "Zplayer".
        var player: String?

        private enum CodingKeys: String, CodingKey {
            case title, artist, album, isVideo = "video", isPlaying = "playing", player
        }

        init(title: String, artist: String?, album: String?, isVideo: Bool = false, isPlaying: Bool = true,
             player: String?) {
            self.title = title
            self.artist = artist?.nilIfBlank
            self.album = album?.nilIfBlank
            self.isVideo = isVideo
            self.isPlaying = isPlaying
            self.player = player
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            artist = try c.decodeIfPresent(String.self, forKey: .artist)?.nilIfBlank
            album = try c.decodeIfPresent(String.self, forKey: .album)?.nilIfBlank
            isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
            isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? true
            player = try c.decodeIfPresent(String.self, forKey: .player)
        }
    }

    /// The latest announcement from each player, by player name.
    private var announced: [String: Track?] = [:]

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.announcement, object: nil, queue: .main) { note in
            let payload = note.object as? String
            MainActor.assumeIsolated { NowPlaying.shared.receive(payload) }
        }
    }

    /// Records one player's announcement. Exposed for tests.
    func receive(_ payload: String?) {
        guard let data = payload?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let player = (object["player"] as? String) ?? "?"
        let track = (try? JSONDecoder().decode(Track.self, from: data)).flatMap { $0.title.nilIfBlank == nil ? nil : $0 }
        announced[player] = .some(track)
    }

    /// What `/np` found.
    enum Outcome: Equatable {
        case playing(Track)
        case nothing
        /// Nothing found, and these open players refused to answer because
        /// Keryx lacks the Automation permission for them.
        case notPermitted([String])
    }

    /// Asks every source, preferring something that's actually playing.
    func current() async -> Outcome {
        DistributedNotificationCenter.default().postNotificationName(Self.request, object: nil,
                                                                     deliverImmediately: true)
        try? await Task.sleep(for: .milliseconds(400))
        var candidates = announced.values.compactMap { $0 }
        var refused: [String] = []
        for player in [ScriptablePlayer.music, .spotify] {
            switch Self.ask(player) {
            case let .track(track): candidates.append(track)
            case let .notPermitted(name): refused.append(name)
            case .none: break
            }
        }
        if let track = candidates.first(where: \.isPlaying) ?? candidates.first { return .playing(track) }
        return refused.isEmpty ? .nothing : .notPermitted(refused)
    }

    // MARK: - AppleScript (Music, Spotify)

    enum ScriptablePlayer: String {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var name: String { self == .music ? "Music" : "Spotify" }
    }

    private enum Answer {
        case track(Track)
        case notPermitted(String)
    }

    /// `errAEEventNotPermitted`: the user hasn't allowed Keryx to automate it.
    private static let notPermittedCode = -1743

    /// Reads the current track if the player is open and playing. Never
    /// launches it: Keryx checks it's running before asking. The player is
    /// named as macOS shows it in your language ("Música", "Music").
    private static func ask(_ player: ScriptablePlayer) -> Answer? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first
        else { return nil }
        let name = app.localizedName ?? player.name
        let source = """
        tell application id "\(player.rawValue)"
            if player state is playing then
                return {name of current track, artist of current track, album of current track}
            end if
        end tell
        return {}
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if (error?[NSAppleScript.errorNumber] as? Int) == notPermittedCode { return .notPermitted(name) }
        guard let result, result.numberOfItems >= 1,
              let title = result.atIndex(1)?.stringValue?.nilIfBlank else { return nil }
        return .track(Track(title: title, artist: result.atIndex(2)?.stringValue,
                            album: result.atIndex(3)?.stringValue, player: name))
    }

    // MARK: - Phrasing

    /// The `/me` text: "is listening to “Song” by Artist (Player)".
    static func action(for track: Track) -> String {
        let player = track.player.map { " (\($0))" } ?? ""
        switch (track.isVideo, track.artist) {
        case (true, _):
            return String(localized: "np.watching", defaultValue: "is watching “\(track.title)”\(player)")
        case (false, let artist?):
            return String(localized: "np.listening.artist", defaultValue: "is listening to “\(track.title)” by \(artist)\(player)")
        case (false, nil):
            return String(localized: "np.listening", defaultValue: "is listening to “\(track.title)”\(player)")
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
