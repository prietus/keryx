# Mentions and notifications

## Mentions (⌘⇧M)

The **@** button in the toolbar, or **⌘⇧M**, lists every line that named you
or used one of your highlight words, on every network, newest first. Click one
to open its conversation; the line flashes so you can see it in context.

It covers the history Keryx has loaded; with chathistory on soju or Ergo that's
usually far back.

## Highlight words

Besides your nick, any word can mention you: `/highlight add keryx release`, or
**Settings › Notifications**. Matches are whole words, ignoring case.
`/highlight` alone lists them.

## Notifications

Keryx notifies you of mentions, private messages, invitations and contacts
coming online. Click a notification to open the conversation.

- Nothing notifies for the conversation you're looking at.
- `/mute` silences a conversation (and on soju, the bouncer remembers it for all
  your clients).
- The **Dock badge** counts conversations with mentions or unread private
  messages.

## Private answers about a channel

Bots and services sometimes answer you privately about a channel. When they tag
it (`+draft/channel-context`), Keryx shows the answer in that channel, marked
*privately*, and its reply button opens the private conversation, so you don't
answer the whole room by mistake.

## Auto-away

Keryx marks you away on every network when you lock the screen, put the display
to sleep, or leave the Mac idle (15 minutes by default), and back when you
return. If you set `/away` yourself, it's left alone. Configure it in
[Settings › Away](../configuration/settings.md#away).
