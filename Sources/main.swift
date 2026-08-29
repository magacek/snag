// snag — X11-style select-to-copy for macOS, plus an fn+option
// clipboard picker.
//
// Copy mechanism: watch for a left-mouse-up that terminated a text selection,
// then post a synthetic Cmd-C. We deliberately do NOT read AXSelectedText: the
// accessibility tree is empty or lazy in Chromium, Electron and any
// canvas-rendered app, whereas every one of them implements Copy.

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

final class SelectCopy {
    static let shared = SelectCopy()

    private var config = Config.load()
    private var tap: CFMachPort?
    private var downPoint = CGPoint.zero
    private var downShift = false
    private var didDrag = false
    private let source = CGEventSource(stateID: .combinedSessionState)

    // fn+option state, tracked ONLY from flagsChanged events. Arrow keys,
    // Home/End and the F-row all set maskSecondaryFn in their own keyDown
    // flags even when fn is not held, so reading the fn bit off a keyDown
    // would fire the picker on any arrow press.
    private var frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    private var castMods: [String] = []
    private var fnDown = false
    private var optDown = false

    private func log(_ msg: String) {
        guard config.verbose else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
    }

    // MARK: Events

    /// Returns false to swallow the event. We swallow ONLY Up/Down/Escape, and
    /// only while the picker is on screen — everything else passes untouched.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            let f = event.flags
            fnDown = f.contains(.maskSecondaryFn)
            optDown = f.contains(.maskAlternate)
            castMods = SelectCopy.modLabels(f)
            if KeyCast.shared.enabled {
                if castMods.isEmpty { KeyCast.shared.dismiss() }
                else if config.demoScope == "all" || (fnDown && optDown) {
                    KeyCast.shared.show(castMods)
                }
            }
            let want = fnDown && optDown && config.historyEnabled && config.enabled

            if want && !Picker.shared.isVisible {
                Picker.shared.show(Array(History.shared.items.prefix(config.historySize)))
                log("picker shown (\(History.shared.items.count) items)")
            } else if !want && Picker.shared.isVisible {
                let i = Picker.shared.selected
                Picker.shared.hide()
                if i > 0 {
                    History.shared.commit(i)
                    log("picker committed item \(i + 1)")
                }
            }

        case .keyDown:
            if KeyCast.shared.enabled,
               let lab = KeyCast.label(forKeyCode: event.getIntegerValueField(.keyboardEventKeycode)),
               config.demoScope == "all" || (fnDown && optDown) {
                KeyCast.shared.show(castMods + [lab])
            }
            guard Picker.shared.isVisible else { return true }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 126, 116: Picker.shared.move(-1); return false   // Up / fn-Up = PageUp
            case 125, 121: Picker.shared.move(1);  return false   // Down / fn-Down = PageDown
            case 124, 119:                                        // Right / fn-Right = End
                if Picker.shared.previewOpen { Picker.shared.hidePreview() }
                else if Picker.shared.selectedImagePath != nil { Picker.shared.showPreview() }
                return false
            case 123, 115:                                        // Left / fn-Left = Home
                self.searchSelection()
                return false
            case 36, 76:                                          // Return / keypad Enter
                self.sendToApp()
                return false
            case 51, 117:                                         // Backspace / fn-Backspace
                History.shared.clear()
                Picker.shared.reload([])
                self.log("history cleared")
                return false
            case 53:  Picker.shared.hide();   return false        // Escape cancels
            default:  return true
            }

        case .leftMouseDown:
            downPoint = event.location
            downShift = event.flags.contains(.maskShift)
            didDrag = false

        case .leftMouseDragged:
            let p = event.location
            if hypot(p.x - downPoint.x, p.y - downPoint.y) >= config.dragThreshold { didDrag = true }

        case .leftMouseUp:
            guard config.enabled else { return true }
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            let multi = config.multiClick && clicks >= 2
            let shift = config.shiftClick && downShift
            guard didDrag || multi || shift else { return true }

            let f = event.flags
            if f.contains(.maskCommand) || f.contains(.maskControl) || f.contains(.maskAlternate) {
                log("skip: modifier held"); return true
            }
            let bundle = frontBundle
            if config.denylist.contains(bundle) {
                log("skip: \(bundle) is denylisted"); return true
            }
            let reason = didDrag ? "drag" : (multi ? "click x\(clicks)" : "shift")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.copyDelayMs)) { [weak self] in
                self?.sendCopy(bundle: bundle, reason: reason)
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system kills a slow tap. Reviving it matters: a dead tap
            // renders exactly like "nothing was selected", forever.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("tap re-enabled")

        default: break
        }
        return true
    }

    /// Left-arrow: look the selected row up. Text goes to Google in Chrome;
    /// an image row has nothing to search for, so it opens the file instead.
    private func searchSelection() {
        var args: [String] = []
        let chrome = FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app")
        if let link = Picker.shared.selectedURL {
            args = chrome ? ["-a", "Google Chrome", link] : [link]
            log("open link -> \(String(link.prefix(60)))")
        } else if let text = Picker.shared.selectedText {
            // .urlQueryAllowed keeps ':' '/' '?' '&' '=' intact, so any of those
            // in the text silently terminate the query. Encode everything except
            // the unreserved set.
            var safe = CharacterSet.alphanumerics
            safe.insert(charactersIn: "-._~")
            let q = String(text.prefix(300)).addingPercentEncoding(withAllowedCharacters: safe) ?? ""
            let url = "https://www.google.com/search?q=" + q
            args = chrome ? ["-a", "Google Chrome", url] : [url]
            log("search -> \(String(text.prefix(40)))")
        } else if let path = Picker.shared.selectedImagePath {
            args = [path]
            log("open image -> \((path as NSString).lastPathComponent)")
        } else {
            return
        }
        Picker.shared.hide()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Return: put the row on the clipboard, bring the target app forward and
    /// paste into it. Does nothing at all when that app is not installed —
    /// no clipboard change, no dismissal, picker stays up.
    private func sendToApp() {
        guard let appPath = Picker.shared.sendTarget else {
            log("send: \(config.sendToApp) not installed — ignoring")
            return
        }
        History.shared.commit(Picker.shared.selected)
        Picker.shared.hide()

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                           configuration: cfg) { [weak self] app, err in
            guard err == nil else {
                self?.log("send: could not open \(appPath)")
                return
            }
            // Activation is asynchronous; a Cmd-V posted before the app is
            // frontmost lands in whatever was there before.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) {
                app?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) {
                    self?.postPaste()
                    self?.log("send -> \((appPath as NSString).lastPathComponent)")
                }
            }
        }
    }

    private func postPaste() {
        let kVK_ANSI_V: CGKeyCode = 0x09
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false)
        else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    static func modLabels(_ f: CGEventFlags) -> [String] {
        var out: [String] = []
        if f.contains(.maskSecondaryFn) { out.append("fn") }
        if f.contains(.maskControl)     { out.append("⌃") }
        if f.contains(.maskAlternate)   { out.append("⌥") }
        if f.contains(.maskShift)       { out.append("⇧") }
        if f.contains(.maskCommand)     { out.append("⌘") }
        return out
    }

    private func postCopy() {
        let kVK_ANSI_C: CGKeyCode = 0x08
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_C, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_C, keyDown: false)
        else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func sendCopy(bundle: String, reason: String) {
        let before = NSPasteboard.general.changeCount
        postCopy()
        log("copy -> \(bundle) (\(reason))")
        // A double-click's selection is not always final 45ms later, and a
        // Cmd-C that lands too early is a silent no-op. If the pasteboard did
        // not move, the copy did not happen — say so, and try once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) { [weak self] in
            guard let self else { return }
            guard NSPasteboard.general.changeCount == before else { return }
            self.log("copy did NOT take in \(bundle) (\(reason)) — retrying")
            self.postCopy()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                if NSPasteboard.general.changeCount == before {
                    self.log("copy still did not take in \(bundle) — selection was probably empty")
                }
            }
        }
    }

    // MARK: Lifecycle

    /// Replace this process image so the next TCC check is made fresh.
    static func reexec() -> Never {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        setenv("SNAG_REEXEC", "1", 1)
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(exe, &argv)
        exit(0)                      // only reached if execv itself failed
    }

    func run() {
        signal(SIGHUP, SIG_IGN)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.frontBundle = app?.bundleIdentifier ?? "?"
        }

        // macOS caches the permission answer per PROCESS. Polling in place can
        // never see a grant made after launch — which is why this used to need a
        // manual `launchctl kickstart` after ticking the box. Re-exec instead:
        // a fresh image re-reads TCC, so the daemon starts by itself within ~3s.
        let firstLaunch = getenv("SNAG_REEXEC") == nil
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: firstLaunch]
        if !AXIsProcessTrustedWithOptions(opts as CFDictionary) {
            if firstLaunch {
                FileHandle.standardError.write("""
                snag: waiting for Accessibility permission.

                  System Settings -> Privacy & Security -> Accessibility
                  add \(Bundle.main.bundlePath) and enable it

                Nothing else to run — snag restarts itself the moment you do.

                """.data(using: .utf8)!)
            }
            Config.publishState("waiting", input: "unknown")
            Thread.sleep(forTimeInterval: 3.0)
            SelectCopy.reexec()
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // must be able to swallow Up/Down for the picker
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                SelectCopy.shared.handle(type, event) ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: nil
        ) else {
            FileHandle.standardError.write("""
            snag: could not create event tap.

            Watching the keyboard needs Input Monitoring as well as Accessibility:
              System Settings -> Privacy & Security -> Input Monitoring

            """.data(using: .utf8)!)
            exit(1)
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup.setEventHandler { [weak self] in
            guard let self else { return }
            self.config = Config.load()
            Picker.shared.setScale(CGFloat(self.config.uiScale))
            Picker.shared.setMotion(ms: self.config.motionMs)
            KeyCast.shared.setScale(CGFloat(self.config.uiScale))
            KeyCast.shared.enabled = self.config.demo
            Picker.shared.sendTarget = FileManager.default.fileExists(atPath: self.config.sendToApp)
                ? self.config.sendToApp : nil
            self.log("config reloaded")
        }
        hup.resume()

        Picker.shared.setScale(CGFloat(config.uiScale))
        // A CGEventTap that includes keyDown/flagsChanged needs Input Monitoring
        // ON TOP OF Accessibility. Without it tapCreate still SUCCEEDS and mouse
        // events still flow — only keyboard events are silently dropped. So the
        // picker is dead while every other signal reads healthy. Check it and say so.
        var inputState = "granted"
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            inputState = "denied"
            if firstLaunch { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
            FileHandle.standardError.write("""
            snag: waiting for Input Monitoring.

            Select-to-copy works without it. The fn+option picker does not:
            a keyboard tap without Input Monitoring is created successfully and
            then silently receives nothing.

              System Settings -> Privacy & Security -> Input Monitoring
              enable snag

            Running anyway — the picker switches on by itself once you do.

            """.data(using: .utf8)!)
            // Unlike Accessibility we do NOT block: select-to-copy is useful on
            // its own. Watch for the grant and re-exec to pick it up.
            let watch = Timer(timeInterval: 3.0, repeats: true) { _ in
                if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                    SelectCopy.reexec()
                }
            }
            RunLoop.main.add(watch, forMode: .common)
        }

        Picker.shared.setMotion(ms: config.motionMs)
        KeyCast.shared.setScale(CGFloat(config.uiScale))
        KeyCast.shared.enabled = config.demo
        Picker.shared.sendTarget = FileManager.default.fileExists(atPath: config.sendToApp)
            ? config.sendToApp : nil
        History.shared.persist = config.persistHistory
        History.shared.start()
        if config.watchScreenshots {
            ScreenshotWatcher.shared.onIngest = { [weak self] path in
                self?.log("screenshot -> clipboard: \((path as NSString).lastPathComponent)")
            }
            ScreenshotWatcher.shared.start(dir: config.screenshotDir)
        }
        Config.publishState("active", input: inputState)
        log("running (threshold=\(config.dragThreshold) delay=\(config.copyDelayMs)ms "
            + "history=\(config.historyEnabled ? String(config.historySize) : "off") "
            + "deny=\(config.denylist.sorted()))")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        app.run()
    }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil, "run":
    SelectCopy.shared.run()

case "demo":
    let want = args.count > 1 ? args[1] : "on"
    guard want == "on" || want == "off" else {
        FileHandle.standardError.write("usage: snag demo [on|off]\n".data(using: .utf8)!)
        exit(2)
    }
    Config.setKey("demo", want == "on" ? "true" : "false")
    print("snag: keystroke overlay is now \(want.uppercased())")
    if want == "on" { print("  hold fn+option and arrow — the chord shows at the top of your main display") }
    print("  show every keystroke instead of just snag's chords: set demo_scope = all")

case "on", "off":
    Config.setEnabled(args[0] == "on")

case "status":
    let c = Config.load()
    var daemon = "not running — launchctl kickstart -k gui/\(getuid())/io.github.magacek.snag"
    var access = "unknown (daemon not running)"
    var input = "unknown (daemon not running)"
    if let (state, inputState, pid) = Config.readState(), kill(pid, 0) == 0 {
        daemon = "running (pid \(pid))"
        access = state == "active" ? "granted"
            : "NOT GRANTED — enable snag in System Settings > Privacy & Security > Accessibility"
        input = inputState == "granted" ? "granted"
            : "NOT GRANTED — picker is dead until you enable snag in Input Monitoring"
    }
    print("""
    snag
      daemon         : \(daemon)
      accessibility  : \(access)
      input monitoring: \(input)
      select-to-copy : \(c.enabled ? "ON" : "OFF  — turn back on with: snag on")
      clipboard picker: \(c.enabled && c.historyEnabled ? "fn+option, last \(c.historySize)" : "off")
      denylist       : \(c.denylist.sorted().joined(separator: ", "))
      verbose log    : \(c.verbose ? "on (~/Library/Logs/snag.log)" : "off")
    """)

case "setup":
    // Homebrew's install sandbox denies writes outside the Cellar and blocks
    // keychain access, so a formula cannot create the app bundle, the signing
    // identity or the LaunchAgent. Running it as an explicit user command can.
    let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let here = exe.deletingLastPathComponent()
    let candidates = [
        here.deletingLastPathComponent().appendingPathComponent("libexec/install.sh"), // brew
        here.appendingPathComponent("install.sh"),                                     // repo
        here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("install.sh"),         // .app
    ]
    guard let script = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) else {
        FileHandle.standardError.write("""
        snag: could not find install.sh next to \(exe.path)

        Clone the repo and run ./install.sh there instead:
          git clone https://github.com/magacek/snag.git && cd snag && ./install.sh

        """.data(using: .utf8)!)
        exit(1)
    }
    let proc = Process()
    proc.executableURL = script
    var env = ProcessInfo.processInfo.environment
    env["SNAG_SKIP_SHIM"] = "1"
    proc.environment = env
    try? proc.run()
    proc.waitUntilExit()
    exit(proc.terminationStatus)

case "screenshots":
    // Point macOS's own screen capture at a folder we watch. This edits a system
    // preference, so it is an explicit command, never a side effect of install.
    let reset = args.count > 1 && (args[1] == "--reset" || args[1] == "reset")
    let target = reset ? ("~/Desktop" as NSString).expandingTildeInPath
                       : ((args.count > 1 ? args[1] : "~/Desktop/Screenshots") as NSString).expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    func sh(_ exe: String, _ a: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = a
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    sh("/usr/bin/defaults", ["write", "com.apple.screencapture", "location", target])
    // The floating thumbnail is why a screenshot takes ~5s to reach the
    // clipboard: macOS holds the file until the thumbnail flies away or times
    // out. Off, the file lands immediately and so does the clipboard.
    sh("/usr/bin/defaults", ["write", "com.apple.screencapture", "show-thumbnail",
                             "-bool", reset ? "true" : "false"])
    sh("/usr/bin/killall", ["SystemUIServer"])
    print("snag: screenshots now save to \(target)")
    if !reset {
        print("  the daemon watches that folder and puts each new shot on your clipboard")
        print("  floating thumbnail turned OFF so the file — and the clipboard — land instantly")
    } else {
        print("  floating thumbnail restored")
    }
    print("  undo with: snag screenshots --reset")

case "render":
    _ = NSApplication.shared
    let out = args.count > 1 ? args[1] : "/tmp/snag-hud.png"
    let sel = args.count > 2 ? (Int(args[2]) ?? 0) : 0
    let sample: [Clip] = (args.contains("--empty")) ? [] : [
        .text("select id, count(*) from events where created_at >= now() - interval '7 day'"),
        .text("https://github.com/magacek/snag"),
        .image("/Users/x/Desktop/Screenshots/Screenshot 2026-08-29 at 06.21.00.png"),
        .text("git rebase origin/main && git push --force-with-lease"),
        .text("The event tap is listen-only; it never swallows a click."),
        .text("CGEvent.tapCreate(tap:place:options:eventsOfInterest:callback:userInfo:)"),
        .text("launchctl kickstart -k gui/501/io.github.magacek.snag"),
        .text("drag_threshold = 4"),
        .text("kIOHIDRequestTypeListenEvent"),
        .text("AXIsProcessTrustedWithOptions"),
        .text("~/.config/snag/config"),
        .text("~/Library/Logs/snag.log"),
    ]
    Picker.shared.setScale(CGFloat(Config.load().uiScale))
    Picker.shared.renderPNG(sample, to: out, selected: sel)
    print("wrote \(out)")

case "--version", "version":
    print("snag 0.2.0")

case "--help", "-h", "help":
    print("""
    snag — select-to-copy for every macOS app

    usage: snag [run|setup|on|off|status|screenshots|render|version|help]

      setup         build the app bundle, sign it, load the LaunchAgent
                    and open both permission panes (run this after brew install)
      demo on|off   keystroke overlay at the top of the main display
      on / off      pause or resume select-to-copy instantly
      status        is it up, is it armed, are permissions granted
      screenshots   send macOS screenshots to a watched folder
                    (snag screenshots [dir] | --reset)
      render        render the picker offscreen to a PNG
                    (snag render out.png [selected-row] [--empty])

    Clipboard picker: hold fn+option, arrow up/down, release to paste that one.
    ↑↓ move · ← open link / search · → preview · ⏎ send to Claude · ⌫ clear.

    Config: \(Config.path)
      enabled        = true
      drag_threshold = 4
      copy_delay_ms  = 45
      multi_click    = true
      shift_click    = true
      history        = true   # the fn+option picker
      history_size   = 12
      ui_scale       = 1.1
      motion_ms      = 130    # picker animation; lower = snappier
      persist        = true   # keep history across restarts
      send_to_app    = /Applications/Claude.app   # ⏎ sends the row here
      screenshot_dir = ~/Desktop/Screenshots
      watch_screenshots = true
      denylist       = com.apple.finder
      verbose        = false

    Reload config without restarting:  killall -HUP snag
    """)

default:
    FileHandle.standardError.write("snag: unknown command '\(args[0])'\n".data(using: .utf8)!)
    exit(2)
}
