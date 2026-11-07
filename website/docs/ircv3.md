# IRCv3

Keryx negotiates these capabilities and uses them when the server offers them.
`/caps` shows what's active on a network.

## Capabilities

| Capability | What it gives you |
| --- | --- |
| `message-tags`, `server-time` | Timestamps from the server; the basis for everything below. |
| `batch` | Grouped replies, history pages, netsplits and netjoins as one line. |
| `labeled-response`, `echo-message` | Your lines turn from grey to ink when the server confirms them. |
| `cap-notify` | Capabilities added or removed while connected. |
| `standard-replies` | Readable `FAIL`/`WARN`/`NOTE` messages. |
| `account-tag`, `account-notify`, `extended-join` | Who's logged in to which account. |
| `away-notify`, `chghost`, `setname`, `invite-notify` | Changes to people, as they happen. |
| `multi-prefix`, `userhost-in-names`, `no-implicit-names` | A full, cheap member list. |
| `sasl` with `draft/sasl-ir` | PLAIN, EXTERNAL (CertFP) and SCRAM-SHA-256. |
| `sts` | Upgrades to TLS and remembers to. |
| `draft/chathistory` | History on scroll: `LATEST`, `BEFORE`, `AFTER`, `AROUND`, `TARGETS`. |
| `draft/event-playback` | Joins, parts and topics in history, not only messages. |
| `draft/multiline` | Multi-line messages arrive as one. |
| `draft/read-marker` | Where you left off, shared across your clients. |
| `draft/message-redaction` | Deleting messages. |
| `draft/metadata-2` | Profiles: display name, pronouns, avatar, homepage, colour, status. |
| `+typing` | Typing indicators. |
| `+draft/react` | Reactions. |
| `+reply` | Threaded replies. |
| `+draft/channel-context` | Private answers about a channel shown in that channel. |
| `MONITOR`, `extended-monitor` | Contacts coming online and going away. |
| `WHOX` | Account, away and bot state for everyone in a channel. |
| Bot mode | Bots labelled as such. |

## ISUPPORT tokens

`CLIENTTAGDENY` (Keryx tells you when a network won't relay reactions or
typing), `draft/FILEHOST`, `draft/ICON` (the network's icon in the sidebar),
`UTF8ONLY`, `MSGREFTYPES`, `CHANMODES` and `EXTBAN` (the right quiet on each
network), `MODES`, `PREFIX`, `CASEMAPPING`.

## soju

`soju.im/bouncer-networks`, `soju.im/no-implicit-names`, `soju.im/FILEHOST`, and
ignores, mutes and pins synced through `soju.im/blocked`, `soju.im/muted` and
`soju.im/pinned`. See [soju](features/soju.md).
