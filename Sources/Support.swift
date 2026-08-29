import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// MARK: - Config

struct Config {
    var dragThreshold: Double = 4.0
    var copyDelayMs: Int = 45
    var multiClick = true
    var shiftClick = true
    var denylist: Set<String> = ["com.apple.finder"]
    var verbose = false
    var enabled = true
    var historySize = 12
    var historyEnabled = true
    var uiScale: Double = 1.1
    var screenshotDir = "~/Desktop/Screenshots"
    var watchScreenshots = true
    var motionMs = 130
    var persistHistory = true
    var sendToApp = "/Applications/Claude.app"

    static let path = ("~/.config/snag/config" as NSString).expandingTildeInPath
    // The daemon publishes its OWN state here. A CLI invocation cannot infer it:
    // a process launched from a terminal inherits the TERMINAL's accessibility
    // grant, so AXIsProcessTrusted() in the CLI returns true while the
    // launchd-spawned daemon is still locked out.
    static let statePath = ("~/.local/state/snag/state" as NSString).expandingTildeInPath

    static func publishState(_ value: String, input: String = "unknown") {
        let dir = (statePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(value) \(input) \(ProcessInfo.processInfo.processIdentifier)\n"
            .write(toFile: statePath, atomically: true, encoding: .utf8)
    }

    static func readState() -> (String, String, Int32)? {
        guard let raw = try? String(contentsOfFile: statePath, encoding: .utf8) else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 3, let pid = Int32(parts[2]) else { return nil }
        return (String(parts[0]), String(parts[1]), pid)
    }

    static func load() -> Config {
        var c = Config()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return c }
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
            let k = s[s.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let v = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch k {
            case "drag_threshold": c.dragThreshold = Double(v) ?? c.dragThreshold
            case "copy_delay_ms":  c.copyDelayMs = Int(v) ?? c.copyDelayMs
            case "multi_click":    c.multiClick = (v == "true")
            case "shift_click":    c.shiftClick = (v == "true")
            case "verbose":        c.verbose = (v == "true")
            case "enabled":        c.enabled = (v == "true")
            case "history":        c.historyEnabled = (v == "true")
            case "history_size":   c.historySize = max(1, min(20, Int(v) ?? 12))
            case "ui_scale":       c.uiScale = max(0.75, min(3.0, Double(v) ?? 1.1))
            case "screenshot_dir": c.screenshotDir = v
            case "watch_screenshots": c.watchScreenshots = (v == "true")
            case "motion_ms":      c.motionMs = max(0, min(400, Int(v) ?? 130))
            case "persist":        c.persistHistory = (v == "true")
            case "send_to_app":    c.sendToApp = (v as NSString).expandingTildeInPath
            case "denylist":
                c.denylist = Set(v.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
            default: break
            }
        }
        return c
    }

    static func setEnabled(_ on: Bool) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        let entry = "enabled = \(on)"
        if let i = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("enabled") && t.contains("=") && !t.hasPrefix("#")
        }) { lines[i] = entry } else { lines.append(entry) }
        // Trailing newline is load-bearing: without it the next line appended to
        // this file fuses onto "enabled = true", the parser reads a value that
        // is not "true", and everything silently switches off.
        if lines.last?.isEmpty == false { lines.append("") }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        k.arguments = ["-HUP", "snag"]
        k.standardError = FileHandle.nullDevice
        try? k.run(); k.waitUntilExit()
        print("snag: select-to-copy is now \(on ? "ON" : "OFF")")
    }
}

// MARK: - Clipboard items

enum Clip: Equatable {
    case text(String)
    case image(String)          // absolute path on disk

    var label: String {
        switch self {
        case .text(let t):
            return t.replacingOccurrences(of: "\n", with: " ⏎ ")
                    .replacingOccurrences(of: "\t", with: "  ")
        case .image(let p):
            return "[image]  " + (p as NSString).lastPathComponent
        }
    }
    var imagePath: String? { if case .image(let p) = self { return p }; return nil }

    /// A row that is already a link should be OPENED, not searched for. Googling
    /// a URL is never what anyone wanted.
    var url: String? {
        guard case .text(let raw) = self else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2048, !t.contains(" "), !t.contains("\n") else { return nil }
        let low = t.lowercased()
        if low.hasPrefix("http://") || low.hasPrefix("https://") { return t }
        guard t.range(of: "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}(/.*)?$",
                      options: .regularExpression) != nil else { return nil }
        let host = low.split(separator: "/").first.map(String.init) ?? low
        if low.contains("/") || host.filter({ $0 == "." }).count >= 2 { return "https://" + t }
        // One dot and no path: "notes.md" is shaped exactly like a domain, and
        // .md, .sh, .py and .co are all real TLDs. Prefer treating it as a file.
        let ext = host.split(separator: ".").last.map(String.init) ?? ""
        let fileExts: Set<String> = ["md","txt","sh","py","rb","go","rs","ts","tsx","js","jsx",
            "json","yml","yaml","toml","csv","tsv","sql","png","jpg","jpeg","gif","svg","pdf",
            "zip","tar","gz","log","conf","cfg","ini","env","lock","swift","java","cpp","html",
            "css","xml","plist","sock","bak","tmp"]
        return fileExts.contains(ext) ? nil : "https://" + t
    }
}

// MARK: - Clipboard history

final class History {
    static let shared = History()
    private(set) var items: [Clip] = []
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let maxStored = 40
    private let maxItemBytes = 100_000

    static let cacheDir = ("~/.local/state/snag/images" as NSString).expandingTildeInPath
    static let storePath = ("~/.local/state/snag/history.json" as NSString).expandingTildeInPath
    var persist = true
    private var saveScheduled = false
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"]

    // Password managers mark their writes with this type by convention. Putting
    // those in a history that renders on screen is exactly the failure this tool
    // must not have.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private var imageHashes: [String: String] = [:]     // sha256 -> path already held

    private func digest(_ path: String) -> String? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // History lived only in memory, so every daemon restart — a rebuild, a
    // crash, a logout — silently emptied it. That reads exactly like "my
    // clipboard cleared itself". It should only ever empty on the keybinding.
    private func load() {
        guard persist,
              let data = try? Data(contentsOf: URL(fileURLWithPath: History.storePath)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return }
        for r in rows {
            guard let kind = r["t"], let v = r["v"] else { continue }
            if kind == "image" {
                // Drop rows whose file has since moved or been deleted, rather
                // than keeping one that would empty the pasteboard on commit.
                if FileManager.default.fileExists(atPath: v) { items.append(.image(v)) }
            } else {
                items.append(.text(v))
            }
        }
        if items.count > maxStored { items.removeLast(items.count - maxStored) }
    }

    private func save() {
        guard persist, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let rows: [[String: String]] = self.items.map {
                switch $0 {
                case .text(let t): return ["t": "text", "v": t]
                case .image(let p): return ["t": "image", "v": p]
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
            try? data.write(to: URL(fileURLWithPath: History.storePath))
            // Clipboard contents on disk are worth keeping to this user alone.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: History.storePath)
        }
    }

    func start() {
        try? FileManager.default.createDirectory(atPath: History.cacheDir,
                                                 withIntermediateDirectories: true)
        load()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.types?.contains(History.concealed) != true else { return }

        // An image on the pasteboard may arrive as a file reference or as raw
        // bitmap data; prefer the file, since it needs no copy and survives.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let u = urls.first,
           History.imageExts.contains(u.pathExtension.lowercased()),
           FileManager.default.fileExists(atPath: u.path) {
            record(.image(u.path)); return
        }
        if let types = pb.types, types.contains(.png) || types.contains(.tiff),
           let path = cacheImageFromPasteboard(pb) {
            record(.image(path)); return
        }
        if let s = pb.string(forType: .string), !s.isEmpty,
           s.utf8.count <= maxItemBytes,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record(.text(s))
        }
    }

    private func cacheImageFromPasteboard(_ pb: NSPasteboard) -> String? {
        var png = pb.data(forType: .png)
        if png == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let data = png else { return nil }
        let name = "clip-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let path = (History.cacheDir as NSString).appendingPathComponent(name)
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        pruneCache()
        return path
    }

    private func pruneCache() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: History.cacheDir), names.count > 40 else { return }
        let paths = names.map { (History.cacheDir as NSString).appendingPathComponent($0) }
        let sorted = paths.sorted {
            let a = (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? nil
            let b = (try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? nil
            return (a ?? .distantPast) > (b ?? .distantPast)
        }
        for p in sorted.dropFirst(40) { try? fm.removeItem(atPath: p) }
    }

    func clear() {
        items.removeAll()
        imageHashes.removeAll()
        try? FileManager.default.removeItem(atPath: History.storePath)
    }

    func record(_ c: Clip) {
        if case .image(let p) = c, let h = digest(p) {
            // Same picture under a different filename: promote the row we
            // already have instead of stacking a duplicate.
            if let known = imageHashes[h], known != p,
               let i = items.firstIndex(of: .image(known)) {
                items.remove(at: i)
                items.insert(.image(known), at: 0)
                return
            }
            imageHashes[h] = p
        }
        items.removeAll { $0 == c }
        items.insert(c, at: 0)
        if items.count > maxStored { items.removeLast(items.count - maxStored) }
        save()
    }

    /// Put an item on the system pasteboard and move it to the front.
    func commit(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        let pb = NSPasteboard.general
        // Build first, clear second. clearContents() followed by a write that
        // yields nothing leaves the pasteboard genuinely EMPTY — a paste that
        // silently produces nothing at all.
        switch item {
        case .text(let t):
            guard !t.isEmpty else { return }
            pb.clearContents()
            pb.setString(t, forType: .string)
        case .image(let p):
            guard let pbItem = History.imageItem(p) else {
                items.remove(at: index)      // file is gone; drop the row
                save()
                return
            }
            pb.clearContents()
            guard pb.writeObjects([pbItem]) else { return }
        }
        lastChangeCount = pb.changeCount     // our own write is not new history
        items.remove(at: index)
        items.insert(item, at: 0)
        save()
    }

    /// One item carrying the file reference AND the bitmap, so it pastes as a
    /// file in Finder and as a picture in Slack or a browser. Separate items
    /// do not: most receivers read only the first.
    static func imageItem(_ path: String) -> NSPasteboardItem? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty
        else { return nil }
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        if path.lowercased().hasSuffix(".png") { item.setData(data, forType: .png) }
        if let rep = NSBitmapImageRep(data: data),
           let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return item
    }

    /// A screenshot that landed on disk: put it on the pasteboard too.
    func ingestFile(_ path: String) {
        let pb = NSPasteboard.general
        guard let pbItem = History.imageItem(path) else { return }
        pb.clearContents()
        guard pb.writeObjects([pbItem]) else { return }
        lastChangeCount = pb.changeCount
        record(.image(path))
    }
}

// MARK: - Screenshot watcher

/// macOS writes screenshots to a FILE; only ctrl-shift-4 puts one on the
/// clipboard. Watching the folder is what makes every screenshot paste-able
/// without changing how you take them.
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var seen = Set<String>()
    private var dir = ""
    var onIngest: ((String) -> Void)?

    func start(dir path: String) {
        stop()
        dir = (path as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Everything already present is history, not news.
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])

        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .extend],
                                                          queue: .main)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { close(f) }
            self?.fd = -1
        }
        s.resume()
        source = s
    }

    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let fresh = names.filter { !seen.contains($0) }
        seen = Set(names)
        for n in fresh where History.imageExts.contains((n as NSString).pathExtension.lowercased()) {
            let full = (dir as NSString).appendingPathComponent(n)
            // screencapture writes progressively; wait for the file to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard FileManager.default.fileExists(atPath: full) else { return }
                History.shared.ingestFile(full)
                self?.onIngest?(full)
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

// MARK: - Picker HUD
//
// Every color, size and duration is lifted verbatim from the approved artboards
// and then multiplied by `ui_scale`. Nothing here may use a system material or
// the system accent color: NSVisualEffectView samples its tint and opacity from
// the desktop behind it and controlAccentColor is whatever the user picked in
// System Settings — both render as "close but not the design".
//
// Layout is computed top-down by hand rather than with isGeometryFlipped. That
// property flips how child layers RENDER as well as where they sit, which is
// what drew the clipboard icon upside down.

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   a).cgColor
}
private func white(_ a: CGFloat) -> CGColor { NSColor(white: 1, alpha: a).cgColor }

private struct Metrics {
    let s: CGFloat
    init(_ scale: CGFloat) { s = scale }

    var panelW: CGFloat   { 400 * s }
    var pad: CGFloat      { 5 * s }
    var rowH: CGFloat     { 26 * s }
    var radius: CGFloat   { 10 * s }
    var rowRadius: CGFloat { 5 * s }
    var headerH: CGFloat  { 27 * s }
    var tickH: CGFloat    { 12 * s }
    var gutter: CGFloat   { 9 * s }
    var emptyH: CGFloat   { 52 * s }
    var iconSize: CGFloat { 16 * s }
    var border: CGFloat   { max(0.5, 0.5 * s) }
    var shadowMargin: CGFloat { 70 * s }
    let maxVisible = 12

    var titleFont: NSFont { .systemFont(ofSize: 11 * s, weight: .medium) }
    var rowFont: NSFont   { .systemFont(ofSize: 12 * s, weight: .regular) }
    var smallFont: NSFont { .systemFont(ofSize: 10 * s, weight: .regular) }
    var tickFont: NSFont  { .monospacedDigitSystemFont(ofSize: 10 * s, weight: .regular) }
}

private enum C {
    static let panelBG   = rgb(0x111114, 0.95)
    static let border    = white(0.09)
    static let topSheen  = white(0.06)
    static let highlight = white(0.075)
    static let hairline  = white(0.06)
    static let titleFG   = rgb(0x9A9AA6)
    static let dimFG     = rgb(0x4A4A53)
    static let rowOn     = rgb(0xEEEEF1)
    static let rowOff    = rgb(0x8E8E99)
    static let emptyFG   = rgb(0x5A5A64)
    static let iconFG    = rgb(0x3D3D45)
}

private enum Motion {
    // Live-tunable via `motion_ms` so timing never costs a rebuild (and, on this
    // machine, a re-grant of two TCC permissions).
    static var slide: CFTimeInterval = 0.13
    static var roll: CFTimeInterval = 0.16
    // easeOutQuad. Two curves failed here for opposite reasons: (0.32,0.72,0,1)
    // ends on a near-flat tail that reads as lag, and (0.33,1,0.68,1) front-loads
    // so hard at a short duration that it reads as a cut. This one spreads the
    // travel evenly enough to actually be seen as movement.
    static let easing = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)

    static func set(ms: Int) {
        slide = CFTimeInterval(max(0, min(400, ms))) / 1000.0
        roll = slide * 1.25
    }
}

private func textLayer(_ s: String, _ font: NSFont, _ color: CGColor,
                       align: CATextLayerAlignmentMode = .left) -> CATextLayer {
    let l = CATextLayer()
    l.string = s
    l.font = font
    l.fontSize = font.pointSize
    l.foregroundColor = color
    l.alignmentMode = align
    l.truncationMode = .end
    l.isWrapped = false
    l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    return l
}

private func measure(_ s: String, _ font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
}

final class Picker {
    static let shared = Picker()

    private var panel: NSPanel?
    private let root = CALayer()
    private var highlight = CALayer()
    private var listClip = CALayer()
    private var listLayer = CALayer()
    private var tickClip = CALayer()
    private var tickStrip = CALayer()
    private var rowLayers: [CATextLayer] = []
    private var entries: [Clip] = []
    private var hintLayer: CATextLayer?
    private var previewPanel: NSPanel?
    var sendTarget: String?          // nil when the app is not installed
    private var previewRoot = CALayer()
    private(set) var previewOpen = false

    private var m = Metrics(1.1)
    private var listH: CGFloat = 0
    private var stripH: CGFloat = 0

    private(set) var isVisible = false
    private(set) var selected = 0
    private var count = 0
    private var visible = 0

    func setScale(_ scale: CGFloat) { m = Metrics(max(0.75, min(3.0, scale))) }
    func setMotion(ms: Int) { Motion.set(ms: ms) }

    private func hintText(for i: Int) -> String {
        guard !entries.isEmpty else { return "hold fn+⌥ · nothing to show" }
        guard entries.indices.contains(i) else { return "↑↓ · ⌫ clear · release to paste" }
        // Only advertise a key that will actually do something.
        let send = sendTarget != nil ? " · ⏎ Claude" : ""
        let action: String
        if entries[i].imagePath != nil   { action = " · → preview" }
        else if entries[i].url != nil    { action = " · ← open link" }
        else                             { action = " · ← search" }
        return "↑↓" + action + send + " · ⌫ clear · release to paste"
    }

    var selectedText: String? {
        guard entries.indices.contains(selected), case .text(let t) = entries[selected] else { return nil }
        return t
    }

    var selectedURL: String? {
        entries.indices.contains(selected) ? entries[selected].url : nil
    }

    /// Rebuild in place — used after clearing, so the panel stays up and drops
    /// straight to the empty state rather than blinking out.
    func reload(_ next: [Clip]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hidePreview()
        rebuild(next)
        CATransaction.commit()
        makePanel().orderFrontRegardless()
    }

    var selectedImagePath: String? {
        entries.indices.contains(selected) ? entries[selected].imagePath : nil
    }

    private func makePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false            // the design's shadow is drawn on the layer
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer = CALayer()
        host.layer?.addSublayer(root)
        p.contentView = host
        panel = p
        return p
    }

    private func rebuild(_ entries: [Clip]) {
        self.entries = entries
        count = entries.count
        visible = min(count, m.maxVisible)
        selected = 0

        let w = m.panelW
        let hasList = !entries.isEmpty
        listH = CGFloat(max(visible, 1)) * m.rowH
        let bodyH = hasList ? listH : m.emptyH
        let listTop = m.pad + m.headerH
        let sepTop = listTop + bodyH + 5 * m.s
        let hintTop = sepTop + 1 + 4 * m.s
        let hintH = 14 * m.s
        let panelH = hasList ? hintTop + hintH + m.pad + 3 * m.s : listTop + m.emptyH + m.pad

        // One helper converts a CSS-style distance-from-top into a CoreAnimation
        // origin, so nothing below has to reason about which way y runs.
        func fromTop(_ top: CGFloat, _ h: CGFloat) -> CGFloat { panelH - top - h }

        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        rowLayers.removeAll()

        root.frame = CGRect(x: m.shadowMargin, y: m.shadowMargin, width: w, height: panelH)
        root.backgroundColor = C.panelBG
        root.cornerRadius = m.radius
        root.borderWidth = m.border
        root.borderColor = C.border
        root.masksToBounds = false
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.60
        root.shadowRadius = 25 * m.s
        root.shadowOffset = CGSize(width: 0, height: -20 * m.s)

        let sheen = CALayer()
        sheen.frame = CGRect(x: m.radius, y: fromTop(0, 0.5), width: w - m.radius * 2, height: 0.5)
        sheen.backgroundColor = C.topSheen
        root.addSublayer(sheen)

        let titleH = 14 * m.s
        let title = textLayer("Clipboard", m.titleFont, C.titleFG)
        title.frame = CGRect(x: m.pad + m.gutter, y: fromTop(m.pad + 6 * m.s, titleH),
                             width: 200 * m.s, height: titleH)
        root.addSublayer(title)

        let right = w - m.pad - m.gutter

        if hasList {
            let totalStr = "/ \(count)"
            let totalW = measure(totalStr, m.smallFont)
            let digitW = measure("\(count)", m.tickFont) + 2 * m.s
            let tickTop = m.pad + 7 * m.s

            let total = textLayer(totalStr, m.smallFont, C.dimFG, align: .right)
            total.frame = CGRect(x: right - totalW, y: fromTop(tickTop, m.tickH),
                                 width: totalW, height: m.tickH)
            root.addSublayer(total)

            tickClip = CALayer()
            tickClip.frame = CGRect(x: right - totalW - 3 * m.s - digitW,
                                    y: fromTop(tickTop, m.tickH), width: digitW, height: m.tickH)
            tickClip.masksToBounds = true
            stripH = CGFloat(count) * m.tickH
            tickStrip = CALayer()
            tickStrip.frame = CGRect(x: 0, y: m.tickH - stripH, width: digitW, height: stripH)
            for i in 0..<count {
                let d = textLayer("\(i + 1)", m.tickFont, C.dimFG, align: .right)
                d.frame = CGRect(x: 0, y: stripH - CGFloat(i) * m.tickH - m.tickH,
                                 width: digitW, height: m.tickH)
                tickStrip.addSublayer(d)
            }
            tickClip.addSublayer(tickStrip)
            root.addSublayer(tickClip)

            listClip = CALayer()
            listClip.frame = CGRect(x: m.pad, y: fromTop(listTop, listH),
                                    width: w - m.pad * 2, height: listH)
            listClip.masksToBounds = true

            highlight = CALayer()
            highlight.frame = CGRect(x: 0, y: listH - m.rowH, width: w - m.pad * 2, height: m.rowH)
            highlight.cornerRadius = m.rowRadius
            highlight.backgroundColor = C.highlight
            listClip.addSublayer(highlight)

            let fullH = CGFloat(count) * m.rowH
            listLayer = CALayer()
            listLayer.frame = CGRect(x: 0, y: listH - fullH, width: w - m.pad * 2, height: fullH)
            let rowTextH = 15 * m.s
            for (i, clip) in entries.enumerated() {
                let l = textLayer(clip.label, m.rowFont, i == 0 ? C.rowOn : C.rowOff)
                l.frame = CGRect(x: m.gutter,
                                 y: fullH - CGFloat(i) * m.rowH - m.rowH + (m.rowH - rowTextH) / 2,
                                 width: w - m.pad * 2 - m.gutter * 2, height: rowTextH)
                listLayer.addSublayer(l)
                rowLayers.append(l)
            }
            listClip.addSublayer(listLayer)
            root.addSublayer(listClip)

            let sep = CALayer()
            sep.frame = CGRect(x: 8 * m.s, y: fromTop(sepTop, 1), width: w - 16 * m.s, height: 1)
            sep.backgroundColor = C.hairline
            root.addSublayer(sep)

            let hint = textLayer(hintText(for: 0), m.smallFont, C.dimFG)
            hintLayer = hint
            hint.frame = CGRect(x: m.pad + m.gutter, y: fromTop(hintTop, hintH),
                                width: 320 * m.s, height: hintH)
            root.addSublayer(hint)
        } else {
            let noteW = 140 * m.s
            let note = textLayer("release to dismiss", m.smallFont, C.dimFG, align: .right)
            note.frame = CGRect(x: right - noteW, y: fromTop(m.pad + 7 * m.s, m.tickH),
                                width: noteW, height: m.tickH)
            root.addSublayer(note)

            // Drawn in CoreAnimation's own orientation: the tab sits at the TOP,
            // which is the HIGHER y here. Getting this backwards is what flipped it.
            let u = m.iconSize / 16
            let icon = CAShapeLayer()
            let p = CGMutablePath()
            p.addRoundedRect(in: CGRect(x: 3.25 * u, y: 2.25 * u, width: 9.5 * u, height: 11.5 * u),
                             cornerWidth: 1.75 * u, cornerHeight: 1.75 * u)
            p.addRect(CGRect(x: 6 * u, y: 12.75 * u, width: 4 * u, height: 2 * u))
            icon.path = p
            icon.fillColor = nil
            icon.strokeColor = C.iconFG
            icon.lineWidth = 1.25 * u
            let iconTop = listTop + (m.emptyH - m.iconSize) / 2
            icon.frame = CGRect(x: m.pad + m.gutter, y: fromTop(iconTop, m.iconSize),
                                width: m.iconSize, height: m.iconSize)
            root.addSublayer(icon)

            let msgH = 16 * m.s
            let msg = textLayer("Nothing copied yet", m.rowFont, C.emptyFG)
            msg.frame = CGRect(x: m.pad + m.gutter + m.iconSize + m.gutter,
                               y: fromTop(listTop + (m.emptyH - msgH) / 2, msgH),
                               width: 300 * m.s, height: msgH)
            root.addSublayer(msg)
        }

        let p = makePanel()
        let outer = NSSize(width: w + m.shadowMargin * 2, height: panelH + m.shadowMargin * 2)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrame(NSRect(x: (screen.midX - outer.width / 2).rounded(),
                          y: (screen.midY - outer.height / 2).rounded(),
                          width: outer.width, height: outer.height), display: false)
        p.contentView?.frame = NSRect(origin: .zero, size: outer)
    }

    func show(_ entries: [Clip]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuild(entries)
        CATransaction.commit()
        makePanel().orderFrontRegardless()
        isVisible = true
    }

    func move(_ delta: Int) {
        guard isVisible, count > 0, !rowLayers.isEmpty else { return }
        let next = max(0, min(count - 1, selected + delta))
        guard next != selected else { return }
        let prev = selected
        selected = next

        var top = 0
        if next > visible - 1 { top = min(next - visible + 1, count - visible) }

        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.slide)
        CATransaction.setAnimationTimingFunction(Motion.easing)
        highlight.frame.origin.y = listH - CGFloat(next - top) * m.rowH - m.rowH
        listLayer.frame.origin.y = listH - listLayer.frame.height + CGFloat(top) * m.rowH
        rowLayers[prev].foregroundColor = C.rowOff
        rowLayers[next].foregroundColor = C.rowOn
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.roll)
        CATransaction.setAnimationTimingFunction(Motion.easing)
        tickStrip.frame.origin.y = CGFloat(next) * m.tickH + m.tickH - stripH
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hintLayer?.string = hintText(for: next)
        CATransaction.commit()

        if previewOpen {
            if selectedImagePath != nil { showPreview() } else { hidePreview() }
        }
    }

    // MARK: preview

    func showPreview() {
        guard let path = selectedImagePath, let img = NSImage(contentsOfFile: path),
              let main = panel else { return }
        let maxW = 420 * m.s, maxH = 300 * m.s
        let size = img.size
        guard size.width > 0, size.height > 0 else { return }
        let fit = min(maxW / size.width, maxH / size.height, 1)
        let iw = (size.width * fit).rounded(), ih = (size.height * fit).rounded()
        let cardW = iw + m.pad * 2, cardH = ih + m.pad * 2

        let p = previewPanel ?? {
            let np = NSPanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            np.isFloatingPanel = true
            np.level = .statusBar
            np.hidesOnDeactivate = false
            np.isOpaque = false
            np.backgroundColor = .clear
            np.hasShadow = false
            np.ignoresMouseEvents = true
            np.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let host = NSView(frame: .zero)
            host.wantsLayer = true
            host.layer = CALayer()
            host.layer?.addSublayer(previewRoot)
            np.contentView = host
            previewPanel = np
            return np
        }()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewRoot.sublayers?.forEach { $0.removeFromSuperlayer() }
        previewRoot.frame = CGRect(x: m.shadowMargin, y: m.shadowMargin, width: cardW, height: cardH)
        previewRoot.backgroundColor = C.panelBG
        previewRoot.cornerRadius = m.radius
        previewRoot.borderWidth = m.border
        previewRoot.borderColor = C.border
        previewRoot.shadowColor = NSColor.black.cgColor
        previewRoot.shadowOpacity = 0.60
        previewRoot.shadowRadius = 25 * m.s
        previewRoot.shadowOffset = CGSize(width: 0, height: -20 * m.s)

        let shot = CALayer()
        shot.frame = CGRect(x: m.pad, y: m.pad, width: iw, height: ih)
        shot.contents = img
        shot.contentsGravity = .resizeAspect
        shot.cornerRadius = m.rowRadius
        shot.masksToBounds = true
        previewRoot.addSublayer(shot)
        CATransaction.commit()

        let outer = NSSize(width: cardW + m.shadowMargin * 2, height: cardH + m.shadowMargin * 2)
        // The panel's WINDOW is bigger than the card by shadowMargin on every
        // side. Positioning by window edges put the preview a whole margin too
        // far away and made the fits-on-screen test wrong by the same amount,
        // which is how it ended up on the left, bleeding off screen.
        let host = main.screen ?? NSScreen.main
        let screen = host?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap = 8 * m.s
        let mainRight = main.frame.maxX - m.shadowMargin
        let mainLeft = main.frame.minX + m.shadowMargin
        var cardX = mainRight + gap
        if cardX + cardW > screen.maxX - 8 { cardX = mainLeft - gap - cardW }
        cardX = max(screen.minX + 8, min(cardX, screen.maxX - cardW - 8))
        var cardY = main.frame.midY - cardH / 2
        cardY = max(screen.minY + 8, min(cardY, screen.maxY - cardH - 8))
        let x = cardX - m.shadowMargin
        let y = cardY - m.shadowMargin
        p.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: outer.width, height: outer.height),
                   display: false)
        p.contentView?.frame = NSRect(origin: .zero, size: outer)
        p.orderFrontRegardless()
        previewOpen = true
    }

    /// Render the panel straight to a PNG. Lets the look be verified without a
    /// screen capture — the alternative was shipping colors nobody had seen.
    func renderPNG(_ entries: [Clip], to path: String, selected index: Int = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuild(entries)
        isVisible = true
        for _ in 0..<index { move(1) }
        isVisible = false
        CATransaction.commit()

        let size = root.bounds.size
        let scale = 2
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width) * scale,
                                         pixelsHigh: Int(size.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        root.render(in: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    func hidePreview() {
        previewPanel?.orderOut(nil)
        previewOpen = false
    }

    func hide() {
        hidePreview()
        panel?.orderOut(nil)
        isVisible = false
    }
}
