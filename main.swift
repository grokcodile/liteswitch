// LiteSwitch — flip any Spotlight panel on from anywhere.
//
// LiteSwitch gives every Spotlight panel its own keyboard shortcut.
//
// macOS 26 gave Spotlight four panels — Apps ⌘1, Files ⌘2, Actions ⌘3,
// Clipboard ⌘4 — reachable only after opening Spotlight itself. LiteSwitch lets
// you assign a global shortcut to each panel directly.
//
// How panels open:
//   • Apps      — launches the system stub /System/Applications/Apps.app
//                 (public API, no permissions, works even if ⌘Space is
//                 remapped). Falls back to synthesis if the stub is missing.
//   • Files / Actions / Clipboard — synthesizes ⌘Space then ⌘2/⌘3/⌘4, the
//                 documented gesture. Needs Accessibility to post keystrokes.
//
// Three "System Tools" ride alongside the panels: a shortcut that opens System
// Settings (with a smart toggle back); a Color Picker that shows the system
// loupe (NSColorSampler) and copies the sampled color; and Text Capture, which
// selects a screen region (via /usr/sbin/screencapture -i), OCRs it with Vision,
// and copies the text. Like Apps, these need no Accessibility permission — the
// system does the screen reading out of process.
//
// Same construction as Key54 (github.com/grokcodile/key54): one file, no
// dependencies, compiled with swiftc. Runs as a background agent — launching
// it by hand opens Settings.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import Vision

// MARK: - Panels

struct Panel {
    let name: String
    let symbol: String            // SF Symbol shown beside the row (fallback)
    let glyphPath: String?        // system template glyph (.icns) to load + tint instead
    let detail: String            // hover tooltip on the icon + title
    let spotlightKey: CGKeyCode   // the ⌘N that selects it inside Spotlight
    let defaultsKey: String
}

// Icons mirror the glyphs macOS Spotlight shows for each panel, all
// monochrome. The Applications tools-"A" isn't an SF Symbol, but it ships as
// the Finder-sidebar template glyph in CoreTypes.bundle — loaded from that
// system path at runtime and tinted like the others (falls back to the
// square.grid.2x2 symbol if the path ever moves). The other three are SF
// Symbols: folder, the two-layer Actions stack, and doc.on.doc for Clipboard
// (Spotlight uses the copy glyph, not a clip).
let sidebarApplications = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarApplicationsFolder.icns"
let panels: [Panel] = [
    Panel(name: "Applications", symbol: "square.grid.2x2", glyphPath: sidebarApplications, detail: "Spotlight's Applications panel — browse and launch any installed app.", spotlightKey: CGKeyCode(kVK_ANSI_1), defaultsKey: "apps"),
    Panel(name: "Files", symbol: "folder", glyphPath: nil, detail: "Spotlight's Files panel — search files and folders across your Mac.", spotlightKey: CGKeyCode(kVK_ANSI_2), defaultsKey: "files"),
    Panel(name: "Actions", symbol: "square.2.layers.3d", glyphPath: nil, detail: "Spotlight's Actions panel — run Shortcuts and quick system actions.", spotlightKey: CGKeyCode(kVK_ANSI_3), defaultsKey: "actions"),
    Panel(name: "Clipboard", symbol: "doc.on.doc", glyphPath: nil, detail: "Spotlight's Clipboard panel — browse your recent clipboard history.", spotlightKey: CGKeyCode(kVK_ANSI_4), defaultsKey: "clipboard"),
    Panel(name: "Settings", symbol: "gear", glyphPath: nil, detail: "Open the System Settings app.", spotlightKey: 0, defaultsKey: "settings"),
    Panel(name: "Color Picker", symbol: "eyedropper", glyphPath: nil, detail: "Sample the color under your cursor with the system loupe and copy its hex to the clipboard.", spotlightKey: 0, defaultsKey: "colorpicker"),
    Panel(name: "Text Capture", symbol: "text.viewfinder", glyphPath: nil, detail: "Select a region of the screen; its text is recognized and copied to the clipboard.", spotlightKey: 0, defaultsKey: "textcapture"),
]

/// Panels shown in the "System Tools" group rather than the "Spotlight" group,
/// and — like Applications — driven without needing Accessibility.
let utilityKeys: Set<String> = ["settings", "colorpicker", "textcapture"]
func isUtility(_ panel: Panel) -> Bool { utilityKeys.contains(panel.defaultsKey) }
/// Rows of option controls a card shows below its shortcut field: each System
/// Tool has one (a checkbox or a select menu); Spotlight panels have none.
func optionRows(_ panel: Panel) -> Int { isUtility(panel) ? 1 : 0 }
/// Panels that work without Accessibility (no keystroke synthesis).
func worksWithoutAX(_ panel: Panel) -> Bool {
    ["apps", "colorpicker", "textcapture"].contains(panel.defaultsKey)
}

extension UserDefaults {
    var settingsToggle: Bool {
        get { object(forKey: "settingsToggle") as? Bool ?? true }
        set { set(newValue, forKey: "settingsToggle") }
    }
    var colorFormat: ColorFormat {
        get { ColorFormat(rawValue: integer(forKey: "colorFormat")) ?? .hex }
        set { set(newValue.rawValue, forKey: "colorFormat") }
    }
    /// Text Capture: keep the OCR line breaks, or flow it onto one line.
    var ocrKeepLineBreaks: Bool {
        get { object(forKey: "ocrKeepLineBreaks") as? Bool ?? true }
        set { set(newValue, forKey: "ocrKeepLineBreaks") }
    }
}

/// The text form a sampled color is copied in. The raw values are stable
/// (persisted in defaults), so only ever append new cases.
enum ColorFormat: Int, CaseIterable {
    case hex = 0, rgb = 1, hsl = 2, swiftUI = 3

    var label: String {
        switch self {
        case .hex: return "Hex"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        case .swiftUI: return "SwiftUI"
        }
    }

    /// Render `color` in this format (always via sRGB for stable numbers).
    func string(for color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let R = Int((r * 255).rounded()), G = Int((g * 255).rounded()), B = Int((b * 255).rounded())
        switch self {
        case .hex: return String(format: "#%02X%02X%02X", R, G, B)
        case .rgb: return "rgb(\(R), \(G), \(B))"
        case .hsl:
            let (h, s, l) = ColorFormat.hsl(r, g, b)
            return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)
        }
    }

    /// sRGB → HSL. Hue in degrees [0,360), saturation/lightness in [0,1].
    private static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h * 60, s, l)
    }
}

/// Virtual keycodes for F1–F20 — the one family allowed as modifier-less
/// hotkeys (they exist to be bare; a bare letter would hijack typing).
let fKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                              103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

/// A recorded shortcut: virtual keycode + Carbon modifier mask.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon mask (cmdKey | shiftKey | optionKey | controlKey)

    /// The one shortcut bound to a panel, if any. Reads the current single-slot
    /// storage, the earlier multi-binding array (taking its first entry), or the
    /// oldest legacy KeyCode/Modifiers layout — migrating forward on save.
    static func load(_ panel: Panel) -> Shortcut? {
        let d = UserDefaults.standard
        if let arr = d.array(forKey: panel.defaultsKey + "Shortcuts") as? [[String: Int]],
           let first = arr.first, let k = first["k"], let m = first["m"] {
            return Shortcut(keyCode: UInt32(k), modifiers: UInt32(m))
        }
        if let code = d.object(forKey: panel.defaultsKey + "KeyCode") as? Int, code >= 0 {
            return Shortcut(keyCode: UInt32(code),
                            modifiers: UInt32(d.integer(forKey: panel.defaultsKey + "Modifiers")))
        }
        return nil
    }

    /// Save (or clear, with nil) a panel's single shortcut.
    static func save(_ shortcut: Shortcut?, _ panel: Panel) {
        let d = UserDefaults.standard
        if let sc = shortcut {
            d.set([["k": Int(sc.keyCode), "m": Int(sc.modifiers)]], forKey: panel.defaultsKey + "Shortcuts")
        } else {
            d.removeObject(forKey: panel.defaultsKey + "Shortcuts")
        }
        d.removeObject(forKey: panel.defaultsKey + "KeyCode")     // drop legacy keys
        d.removeObject(forKey: panel.defaultsKey + "Modifiers")
    }

    /// "⌃⌥⇧⌘X" for display.
    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
            9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`", 49: "Space",
            36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 76: "⌤",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            116: "⇞", 121: "⇟", 115: "↖", 119: "↘", 117: "⌦",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20",
        ]
        return names[code] ?? "key\(code)"
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var idToPanel: [UInt32: Int] = [:]   // EventHotKeyID.id → panel index
    private var hotKeyHandler: EventHandlerRef?
    private var settings: SettingsWindow?
    private let hud = HUD()
    private var axPollTimer: Timer?
    private(set) var hasAccessibility = AXIsProcessTrusted()

    /// Panels whose saved shortcut failed to register (another app owns the
    /// combo) — surfaced in the settings banner.
    private(set) var conflicted: [String] = []

    /// True while the recorder is capturing — all hotkeys are parked so the
    /// combo being recorded can't fire the old binding mid-keystroke.
    var recording = false { didSet { syncHotkeys() } }

    /// True while we're posting the ⌘Space→⌘N sequence. Parking the hotkeys
    /// here too is what makes ⌘1–⌘4 usable AS the global shortcuts (the
    /// natural choice, mirroring Spotlight's own keys): Carbon captures
    /// matching combos even when synthesized, so without parking, our own
    /// posted ⌘N would be eaten by our own registration — and re-trigger it.
    private var synthesizing = false
    private var previousApp: NSRunningApplication?

    var appEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "appEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "appEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if appEnabled, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        // No shortcuts are seeded — a fresh install starts blank, and the user
        // records the ones they want. (Format defaults to Hex, Smart Toggle to
        // On, via their UserDefaults getters.)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        installHandler()
        syncHotkeys()
        watchAccessibility()
        // A user-initiated launch (Finder / Spotlight / Launchpad / Dock / `open`)
        // opens straight to settings. A login auto-launch by launchd stays silent
        // in the background; `applicationShouldHandleReopen` shows the window when
        // the user opens the already-running app again. (Key54 pattern.)
        if !launchedAsLoginItem {
            showSettings()
        }
    }

    /// Whether launchd auto-started us at login (vs. the user opening the app).
    /// The launch Apple Event carries `keyAELaunchedAsLogInItem` only on a login
    /// launch; a user open sends `kAEOpenApplication` without it. MUST be read in
    /// `applicationDidFinishLaunching` — `currentAppleEvent` is nil any earlier.
    private var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
                .enumCodeValue == keyAELaunchedAsLogInItem
    }

    func setAppEnabled(_ on: Bool) {
        appEnabled = on
        if on {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        } else {
            try? SMAppService.mainApp.unregister()
        }
        syncHotkeys()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindow(delegate: self) }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: App tracking

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        if bundleID == "com.apple.systempreferences" || bundleID == Bundle.main.bundleIdentifier { return }
        previousApp = app
    }

    // MARK: Accessibility

    /// Synthesis panels need posting rights. Mirror Key54's approach: track
    /// trust, reconcile hotkeys when it flips, poll while untrusted.
    private func watchAccessibility() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(axChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        axChanged()
    }

    @objc private func axChanged() {
        // The notification can arrive slightly before TCC settles; re-check on
        // a short delay, then keep polling while untrusted (Key54 pattern).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.hasAccessibility {
                self.hasAccessibility = trusted
                self.syncHotkeys()
            }
            self.axPollTimer?.invalidate()
            if !trusted {
                self.axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.axPollTimer?.invalidate()
                    self.hasAccessibility = true
                    self.syncHotkeys()
                }
            }
        }
    }

    func promptForAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Hotkeys

    private func installHandler() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userInfo -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<AppDelegate>.fromOpaque(userInfo!).takeUnretainedValue()
            if let index = me.idToPanel[id.id] {
                DispatchQueue.main.async { me.openPanel(index) }
            }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    /// Reconcile registered hotkeys with saved shortcuts. A registered hotkey
    /// eats its combo system-wide, so only register what can actually work:
    /// Apps and Color Picker always can (no keystroke synthesis, no
    /// permissions); the synthesis panels only when Accessibility is granted.
    /// Nothing while recording. Registration failures (another app owns the
    /// combo) are collected for the settings banner rather than silently ignored.
    func syncHotkeys() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs = []
        idToPanel = [:]
        conflicted = []
        defer { settings?.refreshBanner() }
        guard appEnabled && !recording && !synthesizing else { return }
        var nextId: UInt32 = 1
        for (i, panel) in panels.enumerated() {
            guard worksWithoutAX(panel) || hasAccessibility else { continue }
            guard let sc = Shortcut.load(panel) else { continue }
            let id = EventHotKeyID(signature: OSType(0x4B_4C_49_54) /* 'KLIT' */, id: nextId)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {   // else eventHotKeyExistsErr: Raycast/Alfred owns it
                hotKeyRefs.append(ref)
                idToPanel[nextId] = i
            } else {
                conflicted.append("\(panel.name) (\(sc.label))")
            }
            nextId += 1
        }
    }

    // MARK: Opening panels

    func openPanel(_ index: Int) {
        guard panels.indices.contains(index) else { return }
        let panel = panels[index]

        if panel.defaultsKey == "colorpicker" {
            sampleColor()
            return
        }

        if panel.defaultsKey == "textcapture" {
            captureText()
            return
        }

        if panel.defaultsKey == "settings" {
            let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            let frontmost = NSWorkspace.shared.frontmostApplication
            if UserDefaults.standard.settingsToggle,
               frontmost?.bundleIdentifier == "com.apple.systempreferences" {
                frontmost?.hide()
                if let prev = previousApp, !prev.isTerminated {
                    prev.activate()
                }
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: settingsURL, configuration: config)
            return
        }

        if panel.defaultsKey == "apps" {
            let stub = URL(fileURLWithPath: "/System/Applications/Apps.app")
            if FileManager.default.fileExists(atPath: stub.path) {
                let config = NSWorkspace.OpenConfiguration()
                config.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: stub, configuration: config) { [weak self] _, error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        self?.synthesizeSpotlight(then: panel.spotlightKey)
                    }
                }
                return
            }
        }

        synthesizeSpotlight(then: panel.spotlightKey)
    }

    /// Show the system color loupe (`NSColorSampler`), then copy the picked
    /// color to the clipboard in the user's chosen format — plus the `NSColor`
    /// itself, so it can be dropped straight into a color well — and flash a
    /// brief confirmation pill at the top of the screen. The system sampler
    /// does the screen reading out of process, so this needs no Screen
    /// Recording or Accessibility permission. A nil color means the user
    /// dismissed the loupe (Esc); we leave the clipboard untouched.
    func sampleColor() {
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let code = UserDefaults.standard.colorFormat.string(for: rgb)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code, forType: .string)
            pb.writeObjects([rgb])
            self?.hud.showColor(code: code, color: rgb)
        }
    }

    /// Text Capture: the system's own crosshair region selector
    /// (`/usr/sbin/screencapture -i`) writes a PNG, which Vision OCRs; the text
    /// lands on the clipboard with a confirmation pill. screencapture reads the
    /// screen in its own process, so LiteSwitch needs no Screen Recording grant.
    /// A cancelled selection (Esc) writes no file and is a silent no-op.
    func captureText() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liteswitch-ocr-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", url.path]   // interactive region, silent
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url),
                      let image = NSImage(data: data),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }   // cancelled — nothing written
                self.recognizeText(cg)
            }
        }
        do {
            try task.run()
        } catch {
            hud.showMessage("Couldn’t start capture", symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        }
    }

    private func recognizeText(_ cg: CGImage) {
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            // Preserve the OCR line breaks, or flow onto one line — the user's choice.
            let keep = UserDefaults.standard.ocrKeepLineBreaks
            let text = lines.joined(separator: keep ? "\n" : " ")
            DispatchQueue.main.async {
                guard let self else { return }
                guard !text.isEmpty else {
                    self.hud.showMessage("No text found", symbol: "text.viewfinder", tint: .systemRed)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                // Count lines when breaks are kept, words when they're removed.
                let n = keep ? lines.count : text.split { $0.isWhitespace }.count
                let unit = keep ? (n == 1 ? "line" : "lines") : (n == 1 ? "word" : "words")
                self.hud.showMessage("\(n) \(unit) copied", symbol: "text.viewfinder", tint: .systemGreen)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        }
    }

    /// ⌘Space, small gap, ⌘N — waiting first for the user to release the
    /// non-⌘ modifiers of their shortcut (a lingering ⇧ would turn ⌘4 into
    /// the ⌘⇧4 screenshot shortcut; ⌥/⌃ similarly corrupt the sequence, and
    /// fn is held whenever the shortcut used an F-key on a laptop keyboard).
    /// Timing learnings inherited from Key54's clipboard experiment:
    /// Spotlight buffers keys behind its ⌘Space, but a ~30 ms gap is needed
    /// for cold starts (1 ms was observed to miss).
    private func synthesizeSpotlight(then key: CGKeyCode, attempt: Int = 0) {
        guard hasAccessibility else { return }
        let held = [kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
                    kVK_Control, kVK_RightControl, kVK_Function]
            .contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
        if held {
            // Waiting on the user's fingers: people hold a chord for a long
            // beat when they expect something to appear, so give them 2 s
            // (80 × 25 ms) before quietly giving up, not a fraction of one.
            guard attempt < 80 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.synthesizeSpotlight(then: key, attempt: attempt + 1)
            }
            return
        }
        // ⌘Space is a toggle and there is no permission-free way to ask
        // whether Spotlight is already open (it never becomes the frontmost
        // app, the window list needs Screen Recording, and macOS 27 exposes
        // no Spotlight UI process). We deliberately do NOT guess: an earlier
        // "assume it's still open for a few seconds" heuristic turned every
        // quick successive press into a silent no-op. Always send the full
        // sequence; the rare cost is that a hotkey pressed while Spotlight
        // is already open closes it and the panel key reaches the previous
        // app. (When Spotlight is open it has focus — just press ⌘1–⌘4.)
        // Park our own hotkeys for the duration of the sequence (see the
        // `synthesizing` note above), then reconcile them back afterward.
        synthesizing = true
        syncHotkeys()
        post(CGKeyCode(kVK_Space), .maskCommand)
        let gap = (UserDefaults.standard.object(forKey: "panelDelay")
                   as? Double).map { min(max($0, 0), 1) } ?? 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.post(key, .maskCommand)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.15) { [weak self] in
            self?.synthesizing = false
            self?.syncHotkeys()
        }
    }

    private func post(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key,
                                  keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Shortcut controls

/// A panel's single shortcut field: click to record (replacing any existing
/// binding). Bare Esc / Delete cancels; clearing is via the ✕. Only one
/// recorder captures at a time, and window close / focus loss cancels it —
/// otherwise the parked hotkeys stay parked.
final class RecorderButton: NSButton {
    let panel: Panel
    var restingTitle: String
    private var monitor: Any?
    weak var appDelegate: AppDelegate?
    var onChange: (() -> Void)?
    private var onClear: (() -> Void)?
    private var clearButton: NSButton?
    private var hoverArea: NSTrackingArea?

    /// The one recorder currently capturing, if any.
    private(set) static weak var active: RecorderButton?

    init(panel: Panel, appDelegate: AppDelegate?, restingTitle: String) {
        self.panel = panel
        self.appDelegate = appDelegate
        self.restingTitle = restingTitle
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 11)
        title = restingTitle
        toolTip = "Click to set the shortcut for \(panel.name) — press Delete while recording to clear it."
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Add a ✕ at the field's right edge that clears the binding — revealed
    /// only while the pointer is over the field.
    func enableClear(_ handler: @escaping () -> Void) {
        onClear = handler
        let x = NSButton(frame: .zero)
        x.isBordered = false
        x.title = "✕"
        x.font = .systemFont(ofSize: 10, weight: .medium)
        x.contentTintColor = .tertiaryLabelColor
        x.toolTip = "Clear this shortcut"
        x.target = self
        x.action = #selector(clearTapped)
        x.isHidden = true
        addSubview(x)
        clearButton = x
        positionClear()
    }

    private func positionClear() {
        let s: CGFloat = 16
        clearButton?.frame = NSRect(x: bounds.maxX - s - 5, y: (bounds.height - s) / 2, width: s, height: s)
    }

    override func layout() { super.layout(); positionClear() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseEntered(with event: NSEvent) { clearButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { clearButton?.isHidden = true }

    @objc private func clearTapped() { onClear?() }

    @objc private func beginRecording() {
        RecorderButton.active?.cancelRecording()   // one recorder at a time
        guard monitor == nil else { return }
        RecorderButton.active = self
        appDelegate?.recording = true
        title = "Type keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.cancelRecording() }   // shared teardown for every branch

            var mods: UInt32 = 0
            let f = event.modifierFlags
            if f.contains(.command) { mods |= UInt32(cmdKey) }
            if f.contains(.shift) { mods |= UInt32(shiftKey) }
            if f.contains(.option) { mods |= UInt32(optionKey) }
            if f.contains(.control) { mods |= UInt32(controlKey) }
            let bare = mods & ~UInt32(shiftKey) == 0
            let code = UInt32(event.keyCode)

            // Bare Esc cancels; bare Delete clears the binding (no ✕ button).
            if bare && Int(event.keyCode) == kVK_Escape { return nil }
            if bare && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                Shortcut.save(nil, self.panel)
                return nil
            }
            // Chords need ⌘/⌥/⌃ so a bare letter can't hijack typing
            // system-wide — except F-keys, which exist to be pressed bare.
            guard !bare || fKeyCodes.contains(code) else {
                NSSound.beep()
                return nil
            }

            let sc = Shortcut(keyCode: code, modifiers: mods)
            // One chord belongs to one panel: recording a combo another panel
            // already uses clears it there first.
            for other in panels where other.defaultsKey != self.panel.defaultsKey {
                if Shortcut.load(other) == sc { Shortcut.save(nil, other) }
            }
            Shortcut.save(sc, self.panel)
            // Synthesis panels need Accessibility — ask the moment the user
            // records a binding that will require it.
            if self.panel.defaultsKey != "apps",
               let ad = self.appDelegate, !ad.hasAccessibility {
                ad.promptForAccessibility()
            }
            return nil   // swallow the keystroke
        }
    }

    /// Stop capturing. Safe to call redundantly.
    func cancelRecording() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        if RecorderButton.active === self { RecorderButton.active = nil }
        title = restingTitle
        appDelegate?.recording = false
        onChange?()
    }
}

// MARK: - Settings window

final class SettingsWindow: NSWindow, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var banner: NSTextField?

    // Layout constants — the panels sit side by side, each in its own box.
    private let pad: CGFloat = 20
    // Vertical rhythm mirrored from Key54's settings window: a tall margin
    // under the transparent titlebar, fixed title/switch/description gaps, one
    // consistent section gap before and after the box row, and a Key54-sized
    // button bar.
    private let topMargin: CGFloat = 56
    private let titleTextH: CGFloat = 36
    private let titleSwitchGap: CGFloat = 10
    private let switchRowH: CGFloat = 28
    private let unitGap: CGFloat = 26
    private let descH: CGFloat = 20
    private let sectionGap: CGFloat = 28
    private let btnW: CGFloat = 100, btnH: CGFloat = 32
    private let bottomMargin: CGFloat = 20
    /// Gap between the groups and the button row; the (usually empty)
    /// conflict banner floats inside it rather than reserving its own band.
    private let footerGap: CGFloat = 36
    private var footerH: CGFloat { footerGap + btnH + bottomMargin }
    // Every card — Spotlight panel or System Tool — is the same width.
    private let boxW: CGFloat = 128
    private let boxGap: CGFloat = 12, innerPad: CGFloat = 11
    private let iconSize: CGFloat = 28
    private let headerBlockH: CGFloat = 52   // icon + title (no visible subtitle)
    private let itemH: CGFloat = 26, itemGap: CGFloat = 6
    // Grouping: the Spotlight panels sit in one titled outline box, the System
    // Tools in a second one stacked below it (narrower, centered).
    private let groupTitleH: CGFloat = 18, groupTitleGap: CGFloat = 6
    private let groupPad: CGFloat = 12
    private func groupWidth(_ w: CGFloat, _ count: Int) -> CGFloat {
        groupPad * 2 + w * CGFloat(count) + boxGap * CGFloat(count - 1)
    }
    private var group1W: CGFloat { groupWidth(boxW, spotlightPanels.count) }
    private var group2W: CGFloat { groupWidth(boxW, utilityPanels.count) }
    // The window is as wide as the wider (Spotlight) group.
    private var winW: CGFloat { pad * 2 + group1W }
    private var contentW: CGFloat { winW - pad * 2 }
    private var spotlightPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { !isUtility($0.element) }.map { ($0.offset, $0.element) }
    }
    private var utilityPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { isUtility($0.element) }.map { ($0.offset, $0.element) }
    }
    // Accessibility warning box (Key54's metrics).
    private let warnPadV: CGFloat = 16, warnHeadingH: CGFloat = 20, warnHeadGap: CGFloat = 8
    private let warnBodyStepsGap: CGFloat = 12, warnStepsBtnGap: CGFloat = 14, warnBtnH: CGFloat = 26
    /// Accessibility state the current content was built for — refreshBanner()
    /// triggers a rebuild when trust flips so the warning appears/disappears live.
    private var builtWithAX = true

    init(delegate: AppDelegate) {
        appDelegate = delegate
        // Updated width from 460 to 620 to account for the 5th panel
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = ""
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        self.delegate = self
        rebuild()
        center()
    }

    /// Recreate the whole content from the current shortcuts, so rows grow and
    /// shrink as bindings are added or removed. Called on init and after any
    /// add/remove.
    func rebuild() {
        RecorderButton.active?.cancelRecording()

        // ── Measure ────────────────────────────────────────────────────────
        // Spotlight cards are a header over a single shortcut field. System Tools
        // cards add a self-labeled option menu below the field. Cards in a group
        // share a height; the two stacked groups size to their own tallest column.
        var columnHeights: [CGFloat] = []
        for panel in panels {
            let items = 1 + optionRows(panel)   // shortcut field (+ option rows)
            columnHeights.append(headerBlockH + CGFloat(items) * itemH + CGFloat(items - 1) * itemGap)
        }
        func maxColumn(_ list: [(index: Int, panel: Panel)]) -> CGFloat {
            list.map { columnHeights[$0.index] }.max() ?? headerBlockH
        }
        let spotCardH = maxColumn(spotlightPanels) + innerPad * 2
        let utilCardH = maxColumn(utilityPanels) + innerPad * 2
        let spotGroupBoxH = groupPad * 2 + spotCardH
        let utilGroupBoxH = groupPad * 2 + utilCardH
        let spotGroupH = groupTitleH + groupTitleGap + spotGroupBoxH
        let utilGroupH = groupTitleH + groupTitleGap + utilGroupBoxH
        let groupsH = spotGroupH + sectionGap + utilGroupH   // stacked, gap between

        // Accessibility warning box (Key54 style), only while untrusted. Like
        // Key54, the warning REPLACES the switch, description, and controls:
        // the window shows just the title, the warning, and a centered Quit.
        let hasAX = appDelegate?.hasAccessibility ?? AXIsProcessTrusted()
        builtWithAX = hasAX
        let showControls = hasAX
        let warn = hasAX ? nil : measureWarning()

        let switchBlockH: CGFloat = showControls ? titleSwitchGap + switchRowH + unitGap + descH : 0
        let hdrH = topMargin + titleTextH + switchBlockH + sectionGap
        let H = hdrH + (warn?.boxH ?? 0) + (showControls ? groupsH : 0) + footerH
        let keepTop: CGFloat? = isVisible ? frame.maxY : nil
        setContentSize(NSSize(width: winW, height: H))
        if let top = keepTop { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }

        let v = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: H))

        let enabled = appDelegate?.appEnabled ?? true
        var yTop = H - topMargin

        yTop -= titleTextH
        let titleLabel = NSTextField(labelWithString: "LiteSwitch")
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: pad, y: yTop, width: winW - pad * 2, height: titleTextH)
        v.addSubview(titleLabel)

        if showControls {
            yTop -= titleSwitchGap + switchRowH
            let sw = NSSwitch()
            sw.state = enabled ? .on : .off
            sw.target = self
            sw.action = #selector(appEnabledChanged(_:))
            sw.frame = NSRect(origin: .zero, size: sw.intrinsicContentSize)
            let swW = ceil(sw.frame.width), swH = ceil(sw.frame.height)
            let capLabel = NSTextField(labelWithString: enabled ? "Enabled" : "Disabled")
            capLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            capLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
            capLabel.sizeToFit()
            let capW = ceil(capLabel.frame.width), capH = ceil(capLabel.frame.height)
            let swGap: CGFloat = 8
            let groupX = (winW - (capW + swGap + swW)) / 2
            capLabel.frame = NSRect(x: groupX, y: yTop + (switchRowH - capH) / 2, width: capW, height: capH)
            v.addSubview(capLabel)
            sw.frame = NSRect(x: groupX + capW + swGap, y: yTop + (switchRowH - swH) / 2, width: swW, height: swH)
            v.addSubview(sw)

            yTop -= unitGap + descH
            let desc = NSTextField(labelWithString: "Jump straight to any Spotlight panel — or a system utility — from anywhere, each with its own shortcut.")
            desc.font = .systemFont(ofSize: 12, weight: .regular)
            desc.textColor = .secondaryLabelColor
            desc.alignment = .center
            desc.frame = NSRect(x: pad, y: yTop, width: winW - pad * 2, height: descH)
            v.addSubview(desc)
        }

        let onChange: () -> Void = { [weak self] in self?.appDelegate?.syncHotkeys(); self?.rebuild() }
        var contentTop = H - hdrH

        // Accessibility warning (Key54 style): heading, explanation, numbered
        // steps, and a button straight to the Accessibility pane. Appears only
        // while the permission is missing; rebuild() removes it once granted.
        if let warn {
            let wbox = NSBox(frame: NSRect(x: pad, y: contentTop - warn.boxH, width: contentW, height: warn.boxH))
            wbox.boxType = .custom
            wbox.fillColor = NSColor.systemOrange.withAlphaComponent(0.12)
            wbox.borderColor = NSColor.systemOrange.withAlphaComponent(0.45)
            wbox.borderWidth = 1; wbox.cornerRadius = 10; wbox.titlePosition = .noTitle
            wbox.contentViewMargins = .zero
            v.addSubview(wbox)

            let warnInnerW = contentW - 32
            let heading = NSTextField(labelWithString: "Accessibility Permission Required")
            heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            heading.textColor = .systemOrange
            heading.alignment = .center
            heading.frame = NSRect(x: 16, y: warn.boxH - warnPadV - warnHeadingH, width: warnInnerW, height: warnHeadingH)
            wbox.addSubview(heading)

            let body = NSTextField(labelWithAttributedString: warn.body)
            body.alignment = .center
            body.maximumNumberOfLines = 0
            body.frame = NSRect(x: 16, y: warn.boxH - warnPadV - warnHeadingH - warnHeadGap - warn.bodyH,
                                width: warnInnerW, height: warn.bodyH)
            wbox.addSubview(body)

            let steps = NSTextField(labelWithAttributedString: warn.steps)
            steps.maximumNumberOfLines = 0
            steps.frame = NSRect(x: 16, y: warnPadV + warnBtnH + warnStepsBtnGap, width: warnInnerW, height: warn.stepsH)
            wbox.addSubview(steps)

            let btn = NSButton(title: "Open Privacy & Security Settings", target: self,
                               action: #selector(openAxSettings))
            btn.bezelStyle = .rounded
            btn.frame = NSRect(x: (contentW - 260) / 2, y: warnPadV, width: 260, height: warnBtnH)
            wbox.addSubview(btn)

            contentTop -= warn.boxH + sectionGap
        }

        // ── Two titled outlines, stacked: Spotlight Panels over System Tools ──
        if showControls {

        // Lay out one panel's card at the given left edge / top.
        func layoutCard(_ i: Int, _ panel: Panel, cardX: CGFloat, cardTop: CGFloat, cardH: CGFloat) {
            let bx = cardX
            let cardW = boxW
            let colW = cardW - innerPad * 2

            // The column card — fill only; the group outline carries the border.
            let card = NSView(frame: NSRect(x: bx, y: cardTop - cardH, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            card.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(enabled ? 0.4 : 0.15).cgColor
            card.alphaValue = enabled ? 1 : 0.5
            v.addSubview(card)

            let cx = bx + innerPad
            let top = cardTop - innerPad

            // Icon + title only; the description lives in a hover tooltip on
            // both, keeping each box clean.
            let icon = NSImageView(frame: NSRect(x: cx + (colW - iconSize) / 2, y: top - iconSize, width: iconSize, height: iconSize))
            configureIcon(icon, panel, dimmed: !enabled)
            icon.toolTip = panel.detail
            v.addSubview(icon)

            let name = NSTextField(labelWithString: panel.name)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.alignment = .center
            name.textColor = enabled ? .labelColor : .tertiaryLabelColor
            name.toolTip = panel.detail
            name.frame = NSRect(x: cx, y: top - iconSize - 21, width: colW, height: 17)
            v.addSubview(name)

            var lineTop = top - headerBlockH

            // The single shortcut field, directly under the header. Click to
            // record — replacing any current binding — or press Delete while
            // recording to clear it.
            let sc = Shortcut.load(panel)
            let field = RecorderButton(panel: panel, appDelegate: appDelegate,
                                       restingTitle: sc?.label ?? "Set Shortcut")
            field.alignment = .center
            field.isEnabled = enabled
            field.onChange = onChange
            field.frame = NSRect(x: cx, y: lineTop - itemH, width: colW, height: itemH)
            v.addSubview(field)
            // A hover-revealed ✕ to clear the binding (only when one is set).
            if sc != nil && enabled {
                field.enableClear { [weak self] in
                    Shortcut.save(nil, panel); self?.appDelegate?.syncHotkeys(); self?.rebuild()
                }
            }
            lineTop -= (itemH + itemGap)

            // Tool option below the shortcut. Settings and Text Capture use a
            // checkbox; Color Picker uses a select menu (its copy format).
            func centeredCheckbox(_ title: String, on: Bool, action: Selector, tip: String) {
                let check = NSButton(checkboxWithTitle: title, target: self, action: action)
                check.state = on ? .on : .off
                check.isEnabled = enabled
                check.font = .systemFont(ofSize: 11)
                check.sizeToFit()
                let w = ceil(check.frame.width)
                check.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                check.toolTip = tip
                v.addSubview(check)
            }
            if panel.defaultsKey == "settings" {
                centeredCheckbox("Smart Toggle", on: UserDefaults.standard.settingsToggle,
                                 action: #selector(smartToggleChanged(_:)),
                                 tip: "Smart Toggle gives your Settings shortcut a memory and returns you to the app that was active when you press it a second time.")
            }
            if panel.defaultsKey == "textcapture" {
                centeredCheckbox("Remove Breaks", on: !UserDefaults.standard.ocrKeepLineBreaks,
                                 action: #selector(removeBreaksChanged(_:)),
                                 tip: "On: strip the line breaks and flow the captured text onto one line. Off: keep them.")
            }
            if panel.defaultsKey == "colorpicker" {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: ColorFormat.allCases.map(\.label))
                popup.selectItem(at: UserDefaults.standard.colorFormat.rawValue)
                popup.isEnabled = enabled
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: 11)
                popup.target = self
                popup.action = #selector(colorFormatChanged(_:))
                popup.toolTip = "Which format the sampled color is copied to the clipboard in."
                // Size to its widest label and center it, like the checkboxes.
                popup.sizeToFit()
                let pw = min(ceil(popup.frame.width), colW)
                popup.frame = NSRect(x: cx + (colW - pw) / 2, y: lineTop - itemH, width: pw, height: itemH)
                v.addSubview(popup)
            }
        }

        // Spotlight Panels — full width, on top.
        let g1Box = addGroup("Spotlight Panels", x: pad, width: group1W,
                             top: contentTop, boxH: spotGroupBoxH, dimmed: !enabled, in: v)
        let cardTop1 = g1Box.maxY - groupPad
        for (slot, entry) in spotlightPanels.enumerated() {
            layoutCard(entry.index, entry.panel,
                       cardX: g1Box.minX + groupPad + CGFloat(slot) * (boxW + boxGap),
                       cardTop: cardTop1, cardH: spotCardH)
        }

        // System Tools — narrower, centered beneath.
        let g2Top = contentTop - spotGroupH - sectionGap
        let g2Box = addGroup("System Tools", x: pad + (group1W - group2W) / 2, width: group2W,
                             top: g2Top, boxH: utilGroupBoxH, dimmed: !enabled, in: v)
        let cardTop2 = g2Box.maxY - groupPad
        for (slot, entry) in utilityPanels.enumerated() {
            layoutCard(entry.index, entry.panel,
                       cardX: g2Box.minX + groupPad + CGFloat(slot) * (boxW + boxGap),
                       cardTop: cardTop2, cardH: utilCardH)
        }
        }

        // Footer: banner across the top, Quit (left) + Done (right).
        let bannerField = NSTextField(wrappingLabelWithString: "")
        bannerField.font = .systemFont(ofSize: 11)
        bannerField.textColor = .systemOrange
        bannerField.alignment = .center
        bannerField.frame = NSRect(x: pad, y: bottomMargin + btnH + 8, width: winW - pad * 2, height: 20)
        v.addSubview(bannerField)
        banner = bannerField

        // Key54 pattern: with the warning up there's nothing to save, so the
        // bar is just a centered Quit; otherwise Quit (left) + Done (right).
        let quit = NSButton(title: "Quit", target: self, action: #selector(forceQuit))
        quit.bezelStyle = .rounded
        quit.contentTintColor = .systemRed
        quit.toolTip = "Quit LiteSwitch — its shortcuts stop working until you launch it again."
        quit.frame = NSRect(x: showControls ? pad : (winW - btnW) / 2,
                            y: bottomMargin, width: btnW, height: btnH)
        v.addSubview(quit)

        if showControls {
            let done = NSButton(title: "Done", target: self, action: #selector(saveAndClose))
            done.bezelStyle = .rounded
            done.keyEquivalent = "\r"
            done.toolTip = "Close this window (shortcuts are saved as you set them)."
            done.frame = NSRect(x: winW - pad - btnW, y: bottomMargin, width: btnW, height: btnH)
            v.addSubview(done)
        }

        contentView = v
        refreshBanner()
    }

    // MARK: Layout helpers

    /// A titled outline group: small secondary label above a rounded border box.
    /// Returns the box's frame so callers can place content inside it.
    private func addGroup(_ title: String, x: CGFloat, width: CGFloat, top: CGFloat,
                          boxH: CGFloat, dimmed: Bool, in v: NSView) -> NSRect {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alphaValue = dimmed ? 0.5 : 1
        label.frame = NSRect(x: x + 6, y: top - groupTitleH, width: width - 12, height: groupTitleH)
        v.addSubview(label)
        let boxFrame = NSRect(x: x, y: top - groupTitleH - groupTitleGap - boxH, width: width, height: boxH)
        let box = NSView(frame: boxFrame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.alphaValue = dimmed ? 0.5 : 1
        v.addSubview(box)
        return boxFrame
    }

    /// Measured text + total height for the Accessibility warning box.
    private struct WarnLayout {
        let boxH: CGFloat
        let body: NSAttributedString
        let bodyH: CGFloat
        let steps: NSAttributedString
        let stepsH: CGFloat
    }

    private func measureWarning() -> WarnLayout {
        let warnInnerW = contentW - 32
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let body = NSAttributedString(
            string: "Files, Actions, Clipboard, and the System Settings shortcuts work by synthesizing keystrokes, which needs Accessibility access — Applications and Color Picker work without it.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: para])
        let bodyH = ceil(body.boundingRect(
            with: NSSize(width: warnInnerW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let stepsPara = NSMutableParagraphStyle()
        stepsPara.alignment = .center
        stepsPara.lineSpacing = 3
        let steps = NSAttributedString(
            string: "1 ❯ Click the button below to open System Settings.\n2 ❯ Find LiteSwitch in the list and turn it on.\n3 ❯ Return to this window.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: stepsPara])
        let stepsH = ceil(steps.boundingRect(
            with: NSSize(width: warnInnerW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let boxH = warnPadV + warnHeadingH + warnHeadGap + bodyH
                 + warnBodyStepsGap + stepsH + warnStepsBtnGap + warnBtnH + warnPadV
        return WarnLayout(boxH: boxH, body: body, bodyH: bodyH, steps: steps, stepsH: stepsH)
    }

    @objc private func openAxSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func forceQuit() { NSApp.terminate(nil) }
    @objc private func saveAndClose() { close() }
    @objc private func smartToggleChanged(_ sender: NSButton) {
        UserDefaults.standard.settingsToggle = sender.state == .on
    }

    @objc private func colorFormatChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.colorFormat = ColorFormat(rawValue: sender.indexOfSelectedItem) ?? .hex
    }

    @objc private func removeBreaksChanged(_ sender: NSButton) {
        UserDefaults.standard.ocrKeepLineBreaks = sender.state != .on   // checked = remove breaks
    }

    @objc private func appEnabledChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        appDelegate?.setAppEnabled(on)
        rebuild()
    }

    private func configureIcon(_ icon: NSImageView, _ panel: Panel, dimmed: Bool = false) {
        if let gp = panel.glyphPath, let glyph = NSImage(contentsOfFile: gp) {
            glyph.isTemplate = true
            glyph.size = NSSize(width: 19, height: 19)
            icon.image = glyph
        } else {
            icon.image = NSImage(systemSymbolName: panel.symbol, accessibilityDescription: panel.name)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        }
        icon.contentTintColor = dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
    }

    /// Footer text now carries only hotkey conflicts — the Accessibility story
    /// lives in the warning box, which rebuild() adds/removes as trust flips.
    func refreshBanner() {
        if (appDelegate?.hasAccessibility ?? false) != builtWithAX { rebuild(); return }
        if let conflicts = appDelegate?.conflicted, !conflicts.isEmpty {
            banner?.stringValue = "In use by another app: " + conflicts.joined(separator: ", ")
        } else {
            banner?.stringValue = ""
        }
    }

    // Recording must never outlive the window's key status: a local NSEvent
    // monitor only sees events while we're the active app, so an orphaned
    // recording would park every hotkey with no way to resume them.
    func windowWillClose(_ notification: Notification) { RecorderButton.active?.cancelRecording() }
    func windowDidResignKey(_ notification: Notification) { RecorderButton.active?.cancelRecording() }

    func windowDidBecomeKey(_ notification: Notification) {
        // Re-try conflicted registrations (the other app may have released the
        // combo) and reflect any outside changes.
        appDelegate?.syncHotkeys()
        refreshBanner()
    }
}

// MARK: - HUD

/// A brief, non-interactive pill that flashes at the top-center of the active
/// screen — a color swatch + code after a pick, or an SF Symbol + message after
/// a text capture. It never takes focus, floats above other windows (including
/// full-screen apps), and fades itself out. One reused panel, so a rapid second
/// action just replaces the first.
final class HUD {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private let panelH: CGFloat = 42, padH: CGFloat = 18, gap: CGFloat = 10

    /// Swatch dot in the sampled color + the copied code (Color Picker).
    func showColor(code: String, color: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let textSize = (code as NSString).size(withAttributes: [.font: font])
        let textW = ceil(textSize.width), textH = ceil(textSize.height)
        let dotD: CGFloat = 20
        let width = padH + dotD + gap + textW + padH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))

        let swatch = NSView(frame: NSRect(x: padH, y: (panelH - dotD) / 2, width: dotD, height: dotD))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = dotD / 2
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        content.addSubview(swatch)

        let label = NSTextField(labelWithString: code)
        label.font = font
        label.textColor = .white
        label.frame = NSRect(x: padH + dotD + gap, y: (panelH - textH) / 2, width: textW, height: textH)
        content.addSubview(label)
        present(content, width: width)
    }

    /// SF Symbol + message (Text Capture confirmations), styled like the color pill.
    func showMessage(_ message: String, symbol: String, tint: NSColor) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let measured = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let textW = measured, textH = ceil(font.ascender - font.descender)
        let iconD: CGFloat = 18
        let width = padH + iconD + gap + textW + padH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))

        let icon = NSImageView(frame: NSRect(x: padH, y: (panelH - iconD) / 2, width: iconD, height: iconD))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyDown
        content.addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .white
        label.frame = NSRect(x: padH + iconD + gap, y: (panelH - textH) / 2, width: textW, height: textH)
        content.addSubview(label)
        present(content, width: width)
    }

    /// Shared chrome: frost the pill, center it at the top, fade in, auto-hide.
    private func present(_ content: NSView, width: CGFloat) {
        hideTimer?.invalidate()
        let p = panel ?? makePanel()
        panel = p
        p.setContentSize(NSSize(width: width, height: panelH))

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = panelH / 2
        bg.layer?.masksToBounds = true
        bg.addSubview(content)
        p.contentView = bg

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - panelH - 16))
        }

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in p?.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 42),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
