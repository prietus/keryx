# Commands

Type them in the composer; ⌘K runs them too. `/help` lists them in the app.
Anything Keryx doesn't know is sent to the server as is, so `/motd`, `/list`,
`/knock` and services' own commands work too.

## Conversations

| Command | |
| --- | --- |
| `/join #channel [key]` | Joins a channel; with no arguments, accepts the latest invitation. Also `/j`. |
| `/part [#channel] [reason]` | Leaves a channel. Also `/leave`. |
| `/hop [#channel]` | Leaves and rejoins a channel. Also `/rejoin`, `/cycle`. |
| `/close` | Closes this conversation (and leaves it if it’s a channel). |
| `/query nick [text]` | Opens a private conversation. Also `/q`. |
| `/msg target text` | Sends a message without opening the conversation. Also `/privmsg`. |
| `/me action` | A stage direction in the third person. |
| `/notice target text` | Sends a notice (NOTICE). |
| `/topic [text]` | Shows or changes the channel’s topic. Also `/t`. |
| `/invite nick [#channel]` | Invites someone to the channel. |
| `/clear` | Clears this conversation’s view. |
| `/joins` | Shows or hides joins and parts here. |

## You

| Command | |
| --- | --- |
| `/nick new` | Changes your nick. |
| `/setname real name` | Changes your real name (setname). |
| `/away [reason]` | Marks you as away. |
| `/back` | Marks you as back. |
| `/profile [set key value \| clear key]` | Your profile: display name, pronouns, status… (draft/metadata-2). |
| `/highlight add\|del word…` | Words that mention you besides your nick. |
| `/lang [code \| auto \| off]` | Spelling and word suggestions for this conversation, in a language or detected. |

## People

| Command | |
| --- | --- |
| `/whois nick` | Someone’s profile. Also `/wi`. |
| `/buddy add\|del\|list nick` | Contacts: tells you when they come online (MONITOR). Also `/monitor`. |
| `/ignore [nick \| mask \| $a:account]` | Hides someone (on soju, also blocks them). |
| `/unignore nick` | Stops ignoring. |
| `/dim [nick]` | Dims someone without hiding them. |
| `/undim nick` | Stops dimming. |
| `/ctcp nick VERSION\|PING\|TIME` | Sends a CTCP query. |

## Conversations in the sidebar

| Command | |
| --- | --- |
| `/mute [conversation]` | Silences its notifications. |
| `/unmute [conversation]` | Notifies again. |
| `/pin [conversation]` | Pins it to the top of the sidebar. |
| `/unpin [conversation]` | Unpins it. |

## Messages

| Command | |
| --- | --- |
| `/react emoji` | Reacts to the latest message. |
| `/delete` | Deletes your latest message (draft/message-redaction). Also `/redact`. |
| `/np` | Shares what you’re listening to or watching (from the menu bar’s Now Playing). Also `/nowplaying`. |
| `/exec [-o] script [args] \| -kill` | Runs one of your scripts and shows its output; -o sends it here. |

## Channel operators

| Command | |
| --- | --- |
| `/kick nick [reason]` | Kicks someone from the channel. Also `/k`. |
| `/ban nick\|mask` | Bans someone by their host, or a mask. |
| `/unban nick\|mask` | Lifts a ban. |
| `/kickban nick [reason]` | Bans someone by their host and kicks them. Also `/kb`. |
| `/quiet nick\|mask` | Silences someone without kicking them. |
| `/unquiet nick\|mask` | Lets someone speak again. |
| `/banlist [#channel]` | Lists the channel’s bans. Also `/bans`. |
| `/quietlist [#channel]` | Lists the channel’s quiets. Also `/quiets`. |
| `/op nick…` | Gives operator. |
| `/deop nick…` | Takes operator away. |
| `/halfop nick…` | Gives half-operator. |
| `/dehalfop nick…` | Takes half-operator away. |
| `/voice nick…` | Gives voice. |
| `/devoice nick…` | Takes voice away. |
| `/mode [target] modes` | Changes modes. |
| `/rename #new [reason]` | Renames this channel, where the network allows it. |

## soju

| Command | |
| --- | --- |
| `/detach [#channel]` | Hides a channel while soju stays in it and keeps its history. |
| `/attach #channel` | Brings back a channel detached on soju. |

## Connection

| Command | |
| --- | --- |
| `/reconnect` | Connects again if the connection dropped. Also `/connect`. |
| `/quit [reason]` | Disconnects from this network. Also `/disconnect`. |
| `/caps` | Active IRCv3 capabilities. |
| `/raw line` | Sends a line as is. Also `/quote`. |
| `/help` | Lists the commands. Also `/commands`. |
