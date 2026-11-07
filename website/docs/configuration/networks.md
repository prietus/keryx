# Networks

Add a network with **Add network** at the bottom of the sidebar, or **⌘⇧N**.
Edit one from its context menu in the sidebar (**Edit network…**).

## Server

| Field | |
| --- | --- |
| **Name** | What the sidebar calls it. Empty uses the address. |
| **Address**, **Port** | The server, `6697` for TLS by default. |
| **Encrypted connection (TLS)** | On by default. If a server announces an STS policy, Keryx upgrades to TLS on its own and remembers to. |
| **It's a soju bouncer** | Opens a session per bouncer network. See [soju](../features/soju.md). |
| **Accept unverified certificates** | Only for your own servers with a self-signed certificate. |

## Identity

| Field | |
| --- | --- |
| **Nick** | Required. If it's taken while connecting, Keryx adds `_`. |
| **Username**, **Real name** | Default to the nick. |
| **Server password** | Rarely needed (`PASS`). Stored in the Keychain. |

## Authentication

**SASL method**:

- **None**.
- **Password**: an account (defaults to the nick) and its password.
  SCRAM-SHA-256 is used when the server offers it, PLAIN otherwise.
- **Certificate (CertFP)**: import a `.p12` with its passphrase. Keryx shows the
  certificate's fingerprint so you can register it with NickServ
  (`/msg NickServ CERT ADD`), and authenticates with SASL EXTERNAL.

## On connect

| Field | |
| --- | --- |
| **Channels** | Joined after connecting, separated by spaces. With a bouncer this is rarely needed: it remembers your channels. |
| **Commands** | One per line, run right after connecting and **before** joining. The leading `/` is optional, and `$nick` is replaced by the nick you got. |
| **Connect when Keryx opens** | On by default. |

Some uses for **Commands**:

```text
/mode $nick +x
/msg HostServ ON
/join #private secretkey
```

!!! note
    For NickServ, prefer SASL above: the password stays in the Keychain, while
    commands are saved as plain text in Keryx's settings.

## Your profile

On networks with `draft/metadata-2` (Ergo, and soju passes it on), the network's
context menu has **Your profile…**: display name, pronouns, avatar, homepage,
colour and status, shown to others in their member lists and profile cards.
`/profile` does the same from the keyboard.
