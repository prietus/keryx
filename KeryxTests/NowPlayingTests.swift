import Testing
import Foundation
@testable import Keryx

@MainActor
@Suite("Now playing")
struct NowPlayingTests {
    @Test("A player's JSON announcement decodes, blank fields dropped")
    func decode() throws {
        let json = #"{"player":"Zplayer","title":"Life on Mars?","artist":"David Bowie","album":" ","playing":true}"#
        let track = try JSONDecoder().decode(NowPlaying.Track.self, from: Data(json.utf8))
        #expect(track.title == "Life on Mars?")
        #expect(track.artist == "David Bowie")
        #expect(track.album == nil)
        #expect(track.isPlaying)
        #expect(!track.isVideo)
        #expect(track.player == "Zplayer")
    }

    @Test("/np reads as an action: listening, with or without artist, or watching")
    func phrasing() {
        #expect(NowPlaying.action(for: .init(title: "Song", artist: "Artist", album: nil, player: "Music"))
                == "is listening to “Song” by Artist (Music)")
        #expect(NowPlaying.action(for: .init(title: "Song", artist: nil, album: nil, player: nil))
                == "is listening to “Song”")
        #expect(NowPlaying.action(for: .init(title: "Film", artist: nil, album: nil, isVideo: true, player: "IINA"))
                == "is watching “Film” (IINA)")
    }
}
