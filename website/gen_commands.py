#!/usr/bin/env python3
"""Writes docs/commands.md from the app's own command table
(Keryx/Session/Session+Commands.swift), so the page can't drift from /help.
Run it before `mkdocs build`."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / "Keryx/Session/Session+Commands.swift"

# Other names each command answers to (the `case "x", "y":` spellings).
ALIASES = {
    "join": ["j"], "part": ["leave"], "hop": ["rejoin", "cycle"], "query": ["q"],
    "msg": ["privmsg"], "topic": ["t"], "whois": ["wi"], "kick": ["k"],
    "kickban": ["kb"], "banlist": ["bans"], "quietlist": ["quiets"],
    "buddy": ["monitor"], "np": ["nowplaying"], "delete": ["redact"],
    "raw": ["quote"], "reconnect": ["connect"], "quit": ["disconnect"],
    "help": ["commands"],
}

GROUPS = [
    ("Conversations", ["join", "part", "hop", "close", "query", "msg", "me", "notice", "topic",
                       "invite", "clear", "joins"]),
    ("You", ["nick", "setname", "away", "back", "profile", "highlight", "lang"]),
    ("People", ["whois", "buddy", "ignore", "unignore", "dim", "undim", "ctcp"]),
    ("Conversations in the sidebar", ["mute", "unmute", "pin", "unpin"]),
    ("Messages", ["react", "delete", "np", "exec"]),
    ("Channel operators", ["kick", "ban", "unban", "kickban", "quiet", "unquiet", "banlist",
                           "quietlist", "op", "deop", "halfop", "dehalfop", "voice", "devoice", "mode"]),
    ("soju", ["detach", "attach"]),
    ("Connection", ["reconnect", "quit", "caps", "raw", "help"]),
]

pattern = re.compile(r'\.init\(name: "([^"]+)", usage: String\(localized: "([^"]+)"\), '
                     r'summary: String\(localized: "([^"]+)"\)\)')
commands = {m[0]: (m[1], m[2]) for m in pattern.findall(SOURCE.read_text())}

listed = {name for _, names in GROUPS for name in names}
missing = sorted(set(commands) - listed)
if missing:
    GROUPS.append(("Other", missing))

def cell(text: str) -> str:
    return text.replace("|", "\\|")

out = ["# Commands", "",
       "Type them in the composer; ⌘K runs them too. `/help` lists them in the app.",
       "Anything Keryx doesn't know is sent to the server as is, so `/motd`, `/list`,",
       "`/knock` and services' own commands work too.", ""]
for title, names in GROUPS:
    out += [f"## {title}", "", "| Command | |", "| --- | --- |"]
    for name in names:
        if name not in commands:
            continue
        usage, summary = commands[name]
        aliases = ALIASES.get(name, [])
        note = (" Also " + ", ".join(f"`/{a}`" for a in aliases) + ".") if aliases else ""
        out.append(f"| `{cell(usage)}` | {cell(summary)}{note} |")
    out.append("")

(ROOT / "docs/commands.md").write_text("\n".join(out))
print(f"{len(commands)} commands")
