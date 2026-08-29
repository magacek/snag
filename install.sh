#!/usr/bin/env bash
# snag installer — build, bundle, sign, install, start.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDIR="$HOME/Applications/snag.app"
EXEC="$APPDIR/Contents/MacOS/snag"
SHIM="$HOME/.local/bin/snag"
BUNDLE_ID="io.github.magacek.snag"
LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/snag.log"
SRCDIR="$REPO/Sources"
SIGN_ID="snag-dev"
CONFIG_DIR="$HOME/.config/snag"
STATE_DIR="$HOME/.local/state/snag"

# Paths used by the pre-rename version of this tool. Read-only: we copy out of
# them and never delete them.
OLD_CONFIG_DIR="$HOME/.config/copyonselect"
OLD_STATE_DIR="$HOME/.local/state/copyonselect"
OLD_LABEL="com.copyonselect.daemon"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v swiftc >/dev/null || die "swiftc not found. Run: xcode-select --install"

say "Stopping any running daemon"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

# --- legacy daemon ------------------------------------------------------------
# The tool used to be called copyonselect. Two daemons watching the same mouse
# would each post a Cmd-C, so the old one has to go before the new one starts.
if [ -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" ] \
   || [ -d "$HOME/Applications/copyonselect.app" ]; then
  say "Removing the old copyonselect daemon"
  launchctl bootout "gui/$UID/$OLD_LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" "$HOME/.local/bin/copyonselect"
  rm -rf "$HOME/Applications/copyonselect.app"
fi

# --- migration ----------------------------------------------------------------
# Copy, never move: if you go back to the old build it should still find its own
# files. Only fills in what is not already there.
mkdir -p "$CONFIG_DIR" "$STATE_DIR"
if [ -f "$OLD_CONFIG_DIR/config" ] && [ ! -f "$CONFIG_DIR/config" ]; then
  say "Migrating config from ~/.config/copyonselect/config"
  cp "$OLD_CONFIG_DIR/config" "$CONFIG_DIR/config"
fi
if [ -f "$OLD_STATE_DIR/history.json" ] && [ ! -f "$STATE_DIR/history.json" ]; then
  say "Migrating clipboard history from ~/.local/state/copyonselect/history.json"
  cp "$OLD_STATE_DIR/history.json" "$STATE_DIR/history.json"
  chmod 600 "$STATE_DIR/history.json"
fi

# --- signing identity ---------------------------------------------------------
# Why this exists: TCC does not key Accessibility and Input Monitoring grants to
# the binary's hash. It keys them to the DESIGNATED REQUIREMENT — the bundle
# identifier plus the hash of the signing certificate. Under a stable
# certificate every future rebuild satisfies the same requirement, so the two
# permissions survive an upgrade. Ad-hoc signing (`codesign -s -`) has no
# certificate at all, so each rebuild reads as a brand new program and both
# permissions have to be granted again by hand.
#
# There is no Apple Developer account involved and none is needed: the
# certificate only has to be stable, not trusted.
#
# The PKCS#12 flags are not decoration. openssl 3 defaults to AES-256/PBKDF2 for
# the container, which Security.framework cannot read — `security import` simply
# rejects the file. PBE-SHA1-3DES with a sha1 MAC is the legacy combination it
# accepts.
make_signing_identity() {
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1

  {
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$tmp/snag.key" -out "$tmp/snag.crt" -subj "/CN=$SIGN_ID" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" \
    && openssl pkcs12 -export -out "$tmp/snag.p12" \
      -inkey "$tmp/snag.key" -in "$tmp/snag.crt" \
      -passout pass:snag -name "$SIGN_ID" \
      -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    && security import "$tmp/snag.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P snag -T /usr/bin/codesign -A
  } >/dev/null 2>&1 || rc=1

  rm -rf "$tmp"
  return $rc
}

if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  say "Creating a self-signed code-signing identity ($SIGN_ID)"
  if ! make_signing_identity; then
    warn "could not create $SIGN_ID — falling back to ad-hoc signing."
    warn "snag will still work, but Accessibility and Input Monitoring will have"
    warn "to be re-granted every time you rebuild."
  fi
fi

# A .app bundle is not cosmetic here. macOS TCC identifies accessibility
# clients by bundle, and System Settings' "+" picker only accepts bundles — a
# bare Unix binary frequently never shows in the Accessibility list at all,
# leaving you with a toggle that does not exist to flip.
say "Building app bundle"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$(dirname "$SHIM")" "$(dirname "$LOG")"
swiftc -O -o "$EXEC" "$SRCDIR"/*.swift

say "Installing app icon"
cp "$REPO/Resources/icon.icns" "$APPDIR/Contents/Resources/icon.icns"

cat > "$APPDIR/Contents/Info.plist" <<PLI
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>snag</string>
  <key>CFBundleDisplayName</key><string>snag</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>snag</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>NSAppleEventsUsageDescription</key><string>snag copies your text selection.</string>
</dict>
</plist>
PLI

if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  say "Signing with stable identity ($SIGN_ID)"
  # First use of a freshly imported private key can raise a keychain dialog
  # ("codesign wants to use a key..."). It only happens once; click Always
  # Allow. Until you do, this step waits.
  warn "if a keychain dialog appears, click Always Allow (first run only)"
  codesign --force --deep --sign "$SIGN_ID" "$APPDIR" 2>/dev/null || die "codesign failed"
  NOW_ID="$SIGN_ID"
else
  say "Signing (ad-hoc — permissions will need re-granting each build)"
  codesign --force --deep --sign - "$APPDIR" 2>/dev/null || die "codesign failed"
  NOW_ID="adhoc"
fi

say "Installing CLI shim"
cat > "$SHIM" <<SHIMEOF
#!/bin/sh
exec "$EXEC" "\$@"
SHIMEOF
chmod +x "$SHIM"

say "Writing LaunchAgent"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLI
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$EXEC</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict>
</plist>
PLI

if [ ! -f "$CONFIG_DIR/config" ]; then
  say "Writing default config"
  cat > "$CONFIG_DIR/config" <<CFG
# snag — reload with: killall -HUP snag
enabled        = true
drag_threshold = 4
copy_delay_ms  = 45
multi_click    = true
shift_click    = true
verbose        = false

# Bundle IDs that never get a synthetic Cmd-C, comma separated.
# Finder is here because Cmd-C on files puts FILES on the pasteboard and a
# later Cmd-V performs a real file copy. Remove at your own risk.
denylist = com.apple.finder
CFG
fi

# Only reset when the SIGNING IDENTITY changed. Under a stable identity the
# approvals still match and resetting them would throw away working grants; when
# it changes, a stale entry silently overrides a ticked checkbox.
PREV_ID="$(cat "$STATE_DIR/signid" 2>/dev/null || echo none)"
if [ "$PREV_ID" != "$NOW_ID" ]; then
  say "Signing identity changed ($PREV_ID -> $NOW_ID) — clearing stale approvals"
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset ListenEvent   "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "$NOW_ID" > "$STATE_DIR/signid"
else
  say "Signing identity unchanged — your permissions carry over"
fi

say "Starting daemon"
launchctl bootstrap "gui/$UID" "$PLIST"

# Open both panes for the user. macOS will not let a program grant itself input
# access, so these two ticks are the irreducible manual step — the least we can
# do is not make anyone go hunting through System Settings for them.
if [ "${NEEDS_GRANT:-0}" = "1" ] || ! "$SHIM" status 2>/dev/null | grep -q "accessibility  : granted"; then
  say "Opening both permission panes"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  sleep 1
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
fi

cat <<EOF

$(say "Installed")

  app      $APPDIR
  cli      $SHIM
  config   $CONFIG_DIR/config
  log      $LOG

TWO MANUAL STEPS — macOS will not let a program grant itself input access.
A dialog should have appeared; if you missed it:

  System Settings -> Privacy & Security -> Accessibility
  enable "snag"

  If it is not listed, click + and pick:  $APPDIR
  (In the file picker, Cmd-Shift-G and paste that path.)

  AND in Privacy & Security -> Input Monitoring, enable "snag" too.
  Accessibility alone lets it copy; the fn+option picker needs Input
  Monitoring, and without it keyboard events are withheld SILENTLY —
  the tap succeeds and simply never receives a keystroke.

  Delete any older "snag" or "copyonselect" row first — a stale entry pointing
  at a previous build will never grant the new bundle anything.

snag restarts itself within ~3s of each tick — there is no third command.

Check it took:  snag status
Watch it work:  tail -f $LOG
Remove:         ./uninstall.sh
EOF
