# Install

Keryx needs **macOS 15 Sequoia or later**, on Apple silicon or Intel.

## Homebrew

```sh
brew install --cask prietus/tap/keryx
```

That puts `Keryx.app` in `/Applications`. New versions arrive with the rest of
your casks:

```sh
brew upgrade --cask keryx
```

## Download

Get the latest `Keryx-vX.Y.Z-macOS.zip` from
[GitHub Releases](https://github.com/prietus/keryx/releases/latest), unzip it
and drag `Keryx.app` to Applications.

Every build is signed with a Developer ID and notarized by Apple, so it opens
without Gatekeeper warnings.

## Uninstall

```sh
brew uninstall --cask keryx          # the app only
brew uninstall --cask --zap keryx    # also your networks, scrollback and settings
```

`--zap` removes Keryx's sandbox container
(`~/Library/Containers/im.keryx.mac`). Passwords stay in your Keychain (search
for `im.keryx.secrets` in Keychain Access to remove them), and scripts you put in
`~/Library/Application Scripts/im.keryx.mac` are yours and are left alone.

Without Homebrew, drag the app to the Trash and delete that container folder if
you want your data gone too.

## Build from source

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/prietus/keryx.git
cd keryx
brew install xcodegen
xcodegen generate
xcodebuild -project Keryx.xcodeproj -scheme Keryx build
```

`project.yml` carries the author's team and signing identity: set your own
`DEVELOPMENT_TEAM` before building to run it, or build ad hoc with
`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`.
