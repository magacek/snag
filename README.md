<p align="center">
  <img src="docs/icon.png" alt="snag" width="128" height="128">
</p>

<h1 align="center">snag</h1>


snag is a small macOS daemon that puts every text selection on your clipboard
the moment you finish making it, in every app, the way X11 has always worked. It
also keeps a clipboard history behind an fn+option picker and drops every
screenshot you take straight onto the clipboard.

Swift, no dependencies beyond the Xcode command line tools, installed as a
LaunchAgent.

## Install

```bash
git clone https://github.com/magacek/snag.git
cd snag
./install.sh
```

Or via Homebrew — two commands, because Homebrew's install sandbox cannot write
to your home directory or reach your keychain, and the daemon needs both:

```bash
brew install --HEAD magacek/tap/snag
snag setup
```

The installer builds `~/Applications/snag.app`, signs it, writes the
`io.github.magacek.snag` LaunchAgent and starts it.

The installer opens both System Settings panes, reveals `snag.app` in Finder and
puts its path on your clipboard. Tick **snag** in **Accessibility** and in
**Input Monitoring**; if it is not listed, either drag it from the Finder window
onto the list, or press `+` then ⌘⇧G and ⌘V.

That is the whole install. There is no third command: macOS caches the
permission answer per process, so instead of polling in place the daemon
re-execs itself every few seconds while it waits, and a fresh process reads the
new grant within about three seconds of you ticking the box.

```bash
snag status     # both should read "granted"
```

macOS will not let a program grant itself input access, so those two ticks are
the irreducible manual step. Anything claiming a fully hands-off install on
macOS is either mistaken or doing something you should look at closely.

### Why two permissions

| permission | needed for |
|---|---|
| **Accessibility** | everything. Without it snag blocks at startup and copies nothing. |
| **Input Monitoring** | the fn+option picker, and only that. |

Input Monitoring fails in the worst possible way if you skip it: the event tap
is still created successfully, mouse events still flow, so select-to-copy works
perfectly — and keyboard events are silently withheld, so the picker never
appears and nothing indicates why. `snag status` reports both permissions
separately so you never have to infer which one is missing.

### The signing identity

On first run `install.sh` creates a self-signed code-signing certificate called
`snag-dev` in your login keychain and signs the app bundle with it. This is not
about trust — it is about *stability*. macOS TCC keys a privacy grant to the
app's designated requirement, which is the bundle identifier plus the hash of
the signing certificate, not the hash of the binary. Under a stable certificate
every later rebuild satisfies the same requirement and both permissions survive
the upgrade. Ad-hoc signing has no certificate at all, so each rebuild looks
like a brand new program and you re-grant both permissions by hand every time.

The first `codesign` against a freshly imported key can raise a one-time
keychain dialog — "codesign wants to use a key in your keychain". Click Always
Allow; the installer waits until you do, and it never asks again. Every later
`./install.sh` signs without prompting.

If certificate creation fails for any reason the installer falls back to ad-hoc
signing and says so. Nothing else breaks.

No Apple Developer account is involved and none is needed.

## How it works

The obvious implementation reads `AXSelectedText` from the accessibility tree.
That is what most attempts do, and it is why they cover only some apps:
Chromium, Electron and anything canvas-rendered expose an empty or lazily built
tree, so Chrome, VS Code, Slack, Discord and Figma return nothing.

snag never asks what is selected. It watches for a left-mouse-up that ended a
selection gesture and posts a synthetic **⌘C**, so the app performs its own copy
through its own code path. Any app with a working Copy command works here, which
is effectively all of them.

A selection gesture is one of: a drag past `drag_threshold` points, a double or
triple click, or a shift-click. A plain click never fires, and neither does a
mouse-up with ⌘, ⌃ or ⌥ held.

The event tap is listen-only for mouse events — it observes clicks and never
alters, swallows or delays them. It swallows keystrokes only while the picker is
on screen, and only the keys the picker uses.

## The clipboard picker

Hold **fn+option**. The picker appears in the middle of the screen with the last
`history_size` items. Release to dismiss it.

| key | does |
|---|---|
| ↑ / ↓ | move the selection |
| ← | open the row: a URL opens in the browser, plain text goes to a Google search, an image row opens the file |
| → | toggle the image preview panel (image rows only) |
| ⏎ | commit the row, bring `send_to_app` forward and paste into it — the Claude desktop app by default. Does nothing at all if that app is not installed. |
| ⌫ | clear the entire history, on disk as well |
| esc | dismiss without changing the clipboard |
| release fn+option | put the highlighted row back on the clipboard |

Releasing on row 1 does nothing, because row 1 is already what is on the
clipboard. Releasing on any other row makes it the clipboard contents, so your
next ⌘V pastes it.

Both key layouts are handled deliberately: **fn rewrites the arrow keycodes in
firmware**, so while you are holding fn the arrows arrive as PageUp (116),
PageDown (121), Home (115) and End (119) rather than as 126/125/123/124.
Handling only the arrow keycodes gives you a picker that opens and then ignores
every key you press.

## Screenshots

```bash
snag screenshots            # -> ~/Desktop/Screenshots
snag screenshots ~/Shots    # anywhere you like
snag screenshots --reset    # back to ~/Desktop, unwatched
```

This repoints macOS's own `screencapture` at a folder the daemon watches, so
every screenshot you take lands on the clipboard with no extra keys. It also
turns off the floating thumbnail, which is what otherwise holds the file for
several seconds before it is written — with it off, the file and the clipboard
land immediately. `--reset` restores both settings.

Screenshots appear in the picker as `[image]` rows and are referenced where they
already live. Images copied out of an app arrive as raw bitmap data instead, so
those are cached under `~/.local/state/snag/images` (most recent 40, deduped by
SHA-256 so the same picture under a new filename does not stack up).

Committing an image row writes the file reference and the bitmap together, so it
pastes as a file in Finder and as a picture in Slack or a browser.

## Commands

```bash
snag status         # daemon up? permissions granted? armed?
snag off            # pause instantly; the daemon stays up
snag on             # resume
snag screenshots    # see above
snag --help
```

`status` reports the **daemon's** state, not the CLI's. This matters: a process
launched from a terminal inherits the terminal's accessibility grant, so a naive
`AXIsProcessTrusted()` in the CLI would print "granted" while the launchd daemon
is still locked out and copying nothing. The daemon publishes its real state to
`~/.local/state/snag/state` and `status` reads that.

It runs at login and restarts itself if it dies, so it is on until you say
`snag off`. That setting persists across reboots.

## Config

`~/.config/snag/config` — `key = value` per line, `#` comments. Reload without
restarting: `killall -HUP snag`.

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | master switch; same thing as `snag off` |
| `drag_threshold` | `4` | points of movement before a drag counts as a selection |
| `copy_delay_ms` | `45` | wait before ⌘C so the app has finalized its selection |
| `multi_click` | `true` | double / triple click copies the word / line |
| `shift_click` | `true` | shift-click extends and copies |
| `history` | `true` | the fn+option picker |
| `history_size` | `12` | rows shown in the picker; clamped to 1–20 |
| `ui_scale` | `1.1` | picker size multiplier; clamped to 0.75–3.0 |
| `motion_ms` | `130` | picker animation duration; clamped to 0–400, lower is snappier |
| `persist` | `true` | keep the history across daemon restarts |
| `send_to_app` | `/Applications/Claude.app` | where ⏎ sends the selected row |
| `screenshot_dir` | `~/Desktop/Screenshots` | folder the daemon watches |
| `watch_screenshots` | `true` | put new files in that folder on the clipboard |
| `denylist` | `com.apple.finder` | bundle IDs that never receive a synthetic ⌘C |
| `verbose` | `false` | log every copy to `~/Library/Logs/snag.log` |

Get a bundle ID with `osascript -e 'id of app "Slack"'`.

An unrecognized key is ignored and a malformed number falls back to the default,
so a typo never fails the parse. Booleans are the exception worth knowing: the
parser tests for the literal string `true`, so `multi_click = yes` reads as
false.

## Caveats

**Finder is denylisted by default and you should leave it that way.** ⌘C in
Finder puts *files* on the pasteboard, so a later ⌘V performs a real file copy.
Every other app's ⌘C is inert when nothing is selected, which is why the
denylist is otherwise empty.

**Your clipboard is overwritten every time you highlight anything.** That is the
design, not a bug — macOS has one pasteboard where X11 has two, so there is
nowhere else to put the selection. The picker exists partly to give you the
previous contents back.

**History is written to disk.** `~/.local/state/snag/history.json`, mode 0600,
up to 40 entries, plus cached images under `~/.local/state/snag/images`. Set
`persist = false` to keep history in memory only. `⌫` in the picker deletes the
file.

**Password managers are skipped.** Anything written to the pasteboard with the
`org.nspasteboard.ConcealedType` marker — the convention 1Password and others
follow — is never recorded in the history. That is a convention, not an
enforcement: an app that does not set it is not protected.

**Terminals that already do this natively** (Ghostty's `copy-on-select`, iTerm2)
will copy the same text twice. Harmless.

**No network, no telemetry, no analytics.** snag makes no outbound connections.
The only things it ever launches are `/usr/bin/open` for the ← key, the
`send_to_app` target for ⏎, `defaults` and `killall SystemUIServer` for
`snag screenshots`, and `killall -HUP snag` for `snag on|off`.

## Development

```bash
swiftc -O -o /tmp/snag Sources/*.swift    # what CI does
./install.sh                              # build, bundle, sign, restart
make log                                  # tail the log
```

`snag render out.png [row] [--empty]` renders the picker offscreen straight to a
PNG, so the layout, colors and selection state can be checked without taking a
screen capture or holding a key combination. `docs/design/` holds the source
artboards the picker's metrics were lifted from.

## Uninstall

```bash
./uninstall.sh
```

Removes the LaunchAgent, the app bundle and the CLI shim. Your config and
history are left in place; delete `~/.config/snag` and `~/.local/state/snag` by
hand if you want them gone, and remove the snag rows from Accessibility and
Input Monitoring in System Settings.

## License

MIT — see [LICENSE](LICENSE).
