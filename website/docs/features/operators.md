# Channel operators

When you're an operator, right-click someone in the cast for **Give/Take
operator**, **Give/Take voice**, **Quiet**, **Kick**, **Ban** and **Kick and
Ban**. The same is there as commands:

| Command | |
| --- | --- |
| `/kick nick [reason]` | Kicks someone. Alias `/k`. |
| `/ban nick` or `/ban mask` | Bans someone. |
| `/kickban nick [reason]` | Bans, then kicks, so they can't rejoin in between. Alias `/kb`. |
| `/quiet nick` / `/unquiet nick` | Silences someone without kicking them. |
| `/banlist` / `/quietlist` | Lists the channel's bans or quiets. |
| `/op`, `/deop`, `/voice`, `/devoice nick…` | Several nicks at once, grouped as the server allows. |
| `/halfop`, `/dehalfop nick…` | Where the network has half-operators. |
| `/topic text` | Sets the topic. |
| `/invite nick` | Invites someone here. |
| `/mode +m` | Any other mode. |

## Bans by host

Given a nick, `/ban`, `/kickban` and `/quiet` ban `*!*@host` when Keryx knows
the person's host (from the member list), so a new nick doesn't get round the
ban. If the host isn't known, they fall back to `nick!*@*`. A mask with `!`, `@`
or `*` is used as you wrote it.

## Quiets on each network

Networks silence people in different ways. Keryx reads the server's
`CHANMODES` and `EXTBAN` and picks the right one:

- **Libera, OFTC** and other Solanum/Charybdis networks: the `+q` list.
- **UnrealIRCd**: the `~q:` extban.
- **InspIRCd**: the `m:` extban.
- **Ergo** and others without either: `/quiet` explains instead; use `+m` and
  voice.

## Lists

Replies to `/banlist`, `/quietlist`, and `/mode +e` or `+I` appear as readable
lines in the channel — mask, who set it and when — ending with a count, or
"No bans" when empty.
