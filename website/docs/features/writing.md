# Writing

## Ghost completion

While you type, the rest of the likely word appears in grey after the caret:

- **nicks**, recent speakers first (with `: ` at the start of a line),
- **/commands**,
- **#channels**,
- and **dictionary words** in the conversation's language.

**Tab** accepts and, pressed again, cycles through the other candidates. **→**
accepts.

## Spelling

Keryx uses macOS's own spell checker, underlining as you type. **⌥S** fixes the
nearest typo to the caret.

Each conversation can have its own language: `/lang es`, `/lang en`, `/lang auto`
to detect it, or `/lang off`. The sidebar's context menu has **Writing
language** too.

## Messages

- **↩** sends; **⇧↩** adds a line. On servers with `draft/multiline` a
  multi-line message arrives as one; elsewhere each line is sent in turn.
- Long lines are split at word boundaries under the server's byte limit.
- **↑ / ↓** walk your input history.
- Start a line with `//` to send something that begins with `/`.

## Replies and reactions

Hover a line and click the arrow to **reply**: your message is threaded under
it for clients that support `+reply`, and **Esc** cancels. The smiley adds a
**reaction**; `/react 👍` reacts to the latest message.

`/delete` withdraws your latest message where the server supports
`draft/message-redaction`.

## Uploads

Drag a file into the conversation, or click the paperclip. Keryx uploads it to
the network's file host (soju's `FILEHOST`) or to your own uploader, and puts
the link in the composer. See [Settings › Files](../configuration/settings.md#files).

## Typing

With **Let others know while you type** on, Keryx sends `+typing` so others see
you're writing. When someone else is typing, their name appears at the bottom of
the conversation like a cue in a script.
