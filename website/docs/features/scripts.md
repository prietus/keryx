# Scripts (/exec)

Keryx is sandboxed, so `/exec` runs only what you put in

```text
~/Library/Application Scripts/im.keryx.mac/
```

— the way macOS lets sandboxed apps run user scripts. Keryx can't write there,
so nothing runs that you didn't place yourself.

| Command | |
| --- | --- |
| `/exec` | Lists your scripts and explains how to start. |
| `/exec name args…` | Runs a script and shows its output to you only. |
| `/exec -o name args…` | Sends the output to the conversation (asking first if it's long). |
| `/exec -kill` | Stops the running script. |

Scripts are ordinary executables: a shell script with `#!/bin/sh` and
`chmod +x`, a Python script, a compiled binary.

## Any command, like WeeChat

For `/exec <any command>`, add a script named `sh`:

```sh
D=~/Library/Application\ Scripts/im.keryx.mac
mkdir -p "$D"
printf '#!/bin/sh\ncd "$HOME" || exit 1\nexec /bin/sh -c "$*"\n' > "$D/sh" && chmod +x "$D/sh"
```

Then anything that isn't a script name goes to it:

```text
/exec uptime
/exec -o ls -latr
```

!!! warning
    Whatever you send with `-o` is public in that conversation. Check the output
    first with plain `/exec`.
