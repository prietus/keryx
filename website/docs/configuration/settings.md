# Settings

Open them with **⌘,**.

## Reading

| Setting | |
| --- | --- |
| **Theme** | Automatic, Paper, Sepia, Night or Carbon. See [Themes](../features/themes.md). |
| **Typeface** | System (SF) or Serif (New York). |
| **Body text** | 12 to 20 pt. Also **⌘+** and **⌘−**. |
| **Show joins and parts** | Folded into one line either way. Hide them in one channel with `/joins` or the toolbar button. |
| **Nick changes only for people who spoke** | Lurkers' renames stay out of the way. |
| **Nicks in colour** | Each person keeps the same colour. Mentions of you stay in blue. |
| **Link previews** | A card under the line with the page's title, summary and picture. **Without the summary** makes them one line shorter. |
| **Images in the conversation** | Images and videos. Keryx fetches links to find out what they are; videos never play by themselves. |
| **Play animated GIFs** | With Reduce Motion on in macOS, they stay still and play on hover. |
| **Image size** | Small, medium or large thumbnails. |

## Notifications

| Setting | |
| --- | --- |
| **When you're mentioned** | Your nick or one of your highlight words. |
| **Private messages** | |
| **Words that mention you besides your nick** | Separated by spaces; whole words, ignoring case. Also `/highlight add word`. |

Notifications never interrupt the conversation you're looking at. Mute one
conversation with `/mute` or from the sidebar.

## Away

| Setting | |
| --- | --- |
| **Mark me away when I step away** | On every network, and back when you return. An `/away` of your own is left alone. |
| **When** | When the screen locks, or after 5, 15 (default) or 30 minutes idle. Locking the screen or putting the display to sleep always counts. |
| **Message** | What others see. Empty says "Away". |

## Writing

| Setting | |
| --- | --- |
| **Let others know while you type** | Sends `+typing`, so others see your name as the next cue. |

## Files

Keryx uploads dropped files to the network's file host when it has one
(`draft/FILEHOST`, as soju does), authenticated with your SASL credentials.
Otherwise, or always if you turn that off, it uses your own uploader:

| Setting | |
| --- | --- |
| **Custom uploader** | A [0x0](https://0x0.st)-style endpoint that takes a POST. |
| **Form field** | The multipart field for the file (`file`). Empty sends the file as the body. |
| **Response** | Where the link is: `text` (the body), `location` (the header) or `json:key.path`. |
| **Token** | Sent as `Authorization: Bearer`. |

## Privacy

| Setting | |
| --- | --- |
| **Keep history on this Mac** | So conversations open instantly; the server stays the source. |
| **Privacy mode** | Masks every nick with a stable pseudonym, in the sidebar and inside messages, for screenshots and streaming. **⌘⇧P**. |
