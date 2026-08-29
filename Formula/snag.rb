# Homebrew formula for snag.
#
#   brew tap magacek/tap
#   brew install magacek/tap/snag
#
# Unlike a normal CLI formula this does the FULL setup in post_install: it builds
# a real .app bundle, signs it with a stable self-signed certificate and loads the
# LaunchAgent, then opens both System Settings panes. That is not gratuitous —
# a bare Unix binary often never appears in the Accessibility list at all, and
# ad-hoc signing makes TCC revoke both grants on every upgrade.
class Snag < Formula
  desc "X11-style select-to-copy for every macOS app, with a clipboard picker"
  homepage "https://github.com/magacek/snag"
  url "https://github.com/magacek/snag/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "71003ca3a74766717809e058adf1ad1834779b0bcf78f1d1891f47e90007fa82"
  head "https://github.com/magacek/snag.git", branch: "main"
  license "MIT"
  depends_on :macos

  def install
    libexec.install Dir["*"]
    system "swiftc", "-O", "-o", "snag", *Dir[libexec/"Sources/*.swift"]
    bin.install "snag"
  end

  # No post_install: Homebrew's install sandbox denies writes outside the Cellar
  # and blocks keychain access, so a formula cannot create the app bundle, the
  # signing identity or the per-user LaunchAgent. `snag setup` does it instead.

  def caveats
    <<~EOS
      One more step — brew installed the CLI, not the daemon:

        snag setup

      That builds ~/Applications/snag.app, signs it with a stable self-signed
      certificate, loads the LaunchAgent and opens both System Settings panes.
      Homebrew cannot do it during install: its sandbox blocks writes to your
      home directory and access to your keychain.

      snag then needs TWO permissions in System Settings -> Privacy & Security:

        Accessibility     required for everything; without it nothing is copied.
        Input Monitoring  required only for the fn+option clipboard picker.
                          Skip it and the event tap is still created and mouse
                          events still flow, so select-to-copy keeps working
                          while the picker silently receives no keystrokes.

      Tick snag in both, adding ~/Applications/snag.app with "+" if it is not
      listed. Nothing further to run — the daemon re-execs itself and picks
      up each grant within about three seconds.

      Check what took:  snag status
      Remove entirely:  #{opt_libexec}/uninstall.sh
    EOS
  end

  test do
    assert_match "snag", shell_output("#{bin}/snag version")
  end
end
