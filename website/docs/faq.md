# FAQ

## Where does Keryx keep my data?

Networks, scrollback, the search index and settings live in its sandbox
container, `~/Library/Containers/im.keryx.mac`. Passwords and certificate
passphrases live in the Keychain. Nothing is sent anywhere but to the IRC
servers you add, the link previews you see, and the uploader you configure.

## Why doesn't my network have an icon in the sidebar?

The icon comes from the server (`draft/ICON`). Ergo and soju announce one;
Libera, OFTC and most classic networks don't, so there's nothing to show.

## Keryx asks to control Music or Spotify

That's `/np`: it asks those players what's playing, only when they're already
open. Say no and `/np` just won't see them. Change your mind in **System
Settings › Privacy & Security › Automation**.

## Can I run my own scripts?

Yes, from `~/Library/Application Scripts/im.keryx.mac/`. See
[Scripts](features/scripts.md).

## Does it work without a bouncer?

Yes. Without one you see what's said while Keryx is connected (and what servers
like Ergo keep with chathistory). A bouncer such as [soju](https://soju.im)
keeps everything while your Mac sleeps.

## Is there a Linux or Windows version?

No: Keryx is a native macOS app. Its siblings are
[Arkhe](https://github.com/prietus/arkhe) for iPhone and iPad and
[irkt](https://github.com/prietus/irkt) for the terminal.

## How do I report a bug or ask for a feature?

On [GitHub Issues](https://github.com/prietus/keryx/issues). The network's
protocol log (**⌘⌥L**) helps a lot with connection problems — check it for
anything private before you paste it.
