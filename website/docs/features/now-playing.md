# Now Playing (/np)

`/np` shares what you're listening to or watching as an action:

> ✱ carlos is listening to “Song” by Artist (Music)

The player's name goes in brackets.

macOS no longer lets apps read the menu bar's Now Playing, so Keryx asks
players directly:

- **Music** and **Spotify**, over AppleScript, and only when they're already
  open. The first time, macOS asks whether Keryx may control them.
- **Any player that speaks the protocol below.**

## For player developers

A player posts the distributed notification `im.keryx.NowPlaying` whenever its
track or play state changes, and whenever it sees `im.keryx.NowPlaying.request`.
The payload is a JSON string in the notification's `object` (sandboxed apps
can't send `userInfo`):

```json
{"player": "Zplayer", "title": "…", "artist": "…", "album": "…", "playing": true, "video": false}
```

No `title` means nothing is playing in that player. With `"video": true`, Keryx
says *watching* instead of *listening to*.

In Swift:

```swift
let info: [String: Any] = ["player": "MyPlayer", "title": title, "artist": artist,
                           "album": album, "playing": isPlaying, "video": false]
let json = String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8)
DistributedNotificationCenter.default().postNotificationName(
    .init("im.keryx.NowPlaying"), object: json, userInfo: nil, deliverImmediately: true)
```
