# soju

[soju](https://soju.im) is a modern IRC bouncer: it stays connected for you,
keeps the history and lets several clients share it. Keryx is built to work
with it.

## Connecting

Add your soju as a network and turn on **It's a soju bouncer**. Use your soju
account (SASL **Password** or **Certificate**).

Keryx asks soju for its networks (`soju.im/bouncer-networks`) and opens one
session per network, each in its own section of the sidebar, with its own
channels and private conversations. The account itself stays at the top as a
status window for talking to `BouncerServ`. Networks you add or remove in soju
appear and disappear on their own.

## History

Keryx identifies itself to soju as its own client (`user@keryx-xxxxxx`), so soju
replays exactly what this Mac missed. Scrolling up fetches older history with
`draft/chathistory`, and private conversations you had elsewhere show up
(`TARGETS`). Your read position is shared with your other clients
(`draft/read-marker`).

## Detached channels

`/detach` hides a channel here while soju stays in it and keeps logging it.
`/attach #channel` brings it back with everything said meanwhile.

## Sync through the bouncer

- `/ignore nick` blocks them in soju (`soju.im/blocked`), for all your clients.
- `/mute` silences a conversation's notifications (`soju.im/muted`).
- `/pin` keeps a conversation at the top (`soju.im/pinned`).

## Files

When soju has a file host configured, dropping a file in a conversation uploads
it there, authenticated with your soju account (`soju.im/FILEHOST`).

## On-connect commands

A network's **Commands** run on the connection you configured — for a soju
account, once on the bouncer connection, not on each network under it.
