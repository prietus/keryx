# Getting started

## Your first network

When Keryx opens with no networks it shows **Add network**. The editor offers
**Libera.Chat**, **OFTC** and **Ergo** as starting points; pick one or type
your own server.

1. **Nick**: the name people see. Username and real name default to it.
2. **Authentication**: if you have a registered account, choose **Password**
   and enter your account and password. Keryx prefers SCRAM-SHA-256 when the
   server offers it, so the password never travels; otherwise it uses PLAIN
   over TLS. **Certificate (CertFP)** takes a `.p12` instead.
3. **Channels**: the ones to join on connect, separated by spaces.
4. **Connect**.

Passwords go to the Keychain, never to a file.

!!! tip "Already use a bouncer?"
    Turn on **It's a soju bouncer** and connect to your soju with your soju
    account. Each network the bouncer knows appears in the sidebar on its own.
    See [soju](features/soju.md).

## Finding your way

- The **sidebar** lists networks, their channels and private conversations.
  Pinned conversations come first. A blue dot means something new; a number
  counts what you haven't read; blue numbers mean someone mentioned you.
- **⌘K** opens the palette: type part of a channel or nick to go there, or a
  `/command`.
- **⌘⌥↑ / ⌘⌥↓** move between conversations; **⌘⌥⇧↓** jumps to the next unread.
- The **cast** (member list) is on the right of a channel; **⌘⌥0** shows or
  hides it. Right-click someone for a private conversation, their profile,
  contacts, ignore, and operator actions.

## Talking

Type and press ↩. **⇧↩** starts a new line (sent as one multiline message where
the server supports it). While you type, Keryx suggests the rest of the word in
grey: a nick, a command, a channel or a dictionary word. **Tab** or **→**
accepts it.

- `/join #channel` to join; `/query nick` to talk privately; `/me waves` for an
  action.
- Hover a line to **reply** (it's threaded for clients that support it),
  **react** or copy it.
- Drag a file into the conversation, or click the paperclip, to upload it and
  paste its link.

`/help` lists every command, and [Commands](commands.md) explains them.

## Where you left off

The ⁂ mark shows where you stopped reading. With `draft/read-marker` (soju,
Ergo) it's shared with your other clients, so what you read on your phone is
read here too.

**⌘⇧M** lists everything that mentioned you; **⌘⇧F** searches all your history.
