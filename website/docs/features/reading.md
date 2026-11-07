# Reading

## The transcript

One line per message, every line timed, and the text always starting in the
same column: the speaker column fits the longest nick in view. Consecutive
lines from the same person drop the repeated name.

- **Nick colours**: twelve muted hues, stable per person, the same on every
  network. Lines that mention you are marked in blue with a stroke in the margin.
- **Actions** (`/me`) read as stage directions in the third person.
- **Notices** are set in italics.
- **Your lines** appear in grey the moment you send them and turn to ink when
  the server confirms them (`echo-message`).

## Joins, parts and quiet

Runs of joins, parts, quits and nick changes fold into one line: *"Enter ana,
bob and 3 more. Exit carla."* A netsplit is one line too. Hide them entirely,
or only in one channel with `/joins`. Nick changes can be shown only for people
who recently spoke.

## Replies

When someone answers a message (`+reply`), Keryx sets the answer under the line
it answers if that line is close by — within five messages and ten minutes.
Further away, the answer stays where it arrived, with a one-line quote; click
it to jump to the original.

## Where you left off

The **⁂** mark sits where you stopped reading, with a count of what's new and
how much of it mentions you. With `draft/read-marker` the position is shared
with your other clients through the server. Messages that arrive in the
conversation you're looking at are never counted as unread.

## Links, images and video

- **Link cards** with the site, title, summary and picture, read from the page's
  OpenGraph or Twitter metadata.
- **Images** as thumbnails; click to see them full size.
- **Animated GIFs** play (or wait for hover, with Reduce Motion).
- **Video files** show their first frame and running time; click to play
  inline.
- **Video pages** (YouTube, Vimeo…) get a ▶ card with their duration.
- Pages that just wrap an image — paste sites, your own uploader — show the
  image itself.

## Search and find

- **⌘F** finds in the conversation you're reading.
- **⌘⇧F** searches all history on every network, ignoring accents and case,
  and jumps to the result.

## People

- **Profiles**: right-click someone and choose **Profile**, or `/whois`, for a
  card with their real name, account, server, idle time, channels and, with
  `draft/metadata-2`, display name, pronouns, avatar and status.
- **Bots** are labelled in the cast.
- **Contacts**: `/buddy add nick` or the cast's menu. Keryx tells you when they
  come online (MONITOR), and they get a presence dot in the sidebar.
- **Ignore** hides someone (on soju, the bouncer blocks them for all your
  clients); **Dim** just fades their lines.
