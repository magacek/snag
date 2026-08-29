# brew tap magacek/tap && brew install --HEAD snag
#
# The formula installs the bare binary. That is enough to run snag, but the
# repo's ./install.sh is the better path on a machine you own: it builds a real
# .app bundle and signs it with a stable self-signed certificate, which is what
# lets macOS keep the two privacy grants across upgrades.
class Snag < Formula
  desc "X11-style select-to-copy for every macOS app, with a clipboard picker"
  homepage "https://github.com/magacek/snag"
  head "https://github.com/magacek/snag.git", branch: "main"
  license "MIT"
  depends_on :macos

  def install
    system "swiftc", "-O", "-o", "snag", *Dir["Sources/*.swift"]
    system "codesign", "--force", "--sign", "-", "snag"
    bin.install "snag"
  end

  service do
    run [opt_bin/"snag", "run"]
    keep_alive true
    log_path var/"log/snag.log"
    error_log_path var/"log/snag.log"
  end

  def caveats
    <<~EOS
      snag needs TWO permissions in System Settings -> Privacy & Security:

        Accessibility     required for everything; without it nothing is copied.
        Input Monitoring  required only for the fn+option clipboard picker.
                          Without it the event tap is still created and mouse
                          events still flow, so select-to-copy keeps working
                          while the picker silently receives no keystrokes.

      Grant both, then restart the daemon — macOS caches the accessibility
      check per process:

        brew services restart snag

      Check what actually took:  snag status
    EOS
  end

  test do
    assert_match "snag", shell_output("#{bin}/snag version")
  end
end
