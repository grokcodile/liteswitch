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
// A group of "System Tools" ride alongside the panels, none needing any
// permission: open System Settings (with a smart toggle back); a Color Picker
// (NSColorSampler → clipboard); Text Capture (screencapture -i region → Vision
// OCR → clipboard); Keep Awake (an IOKit power assertion that blocks sleep); and
// Speak Text — which doesn't re-implement speech at all: it mirrors macOS's own
// "Speak selection" (Accessibility → Spoken Content), showing the shortcut that
// feature is assigned and offering a button to enable or change it.
//
// Same construction as Key54 (github.com/grokcodile/key54): one file, no
// dependencies, compiled with swiftc. Runs as a background agent — launching
// it by hand opens Settings.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import Vision
import IOKit.pwr_mgt
import CoreGraphics
import UniformTypeIdentifiers

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
    Panel(name: "Applications", symbol: "square.grid.2x2", glyphPath: sidebarApplications, detail: "Browse and launch any installed app, through Spotlight's Applications panel.", spotlightKey: CGKeyCode(kVK_ANSI_1), defaultsKey: "apps"),
    Panel(name: "Files", symbol: "folder", glyphPath: nil, detail: "Search files and folders across your Mac, without the app and web results.", spotlightKey: CGKeyCode(kVK_ANSI_2), defaultsKey: "files"),
    Panel(name: "Actions", symbol: "square.2.layers.3d", glyphPath: nil, detail: "Run a Shortcut or quick system action by name.", spotlightKey: CGKeyCode(kVK_ANSI_3), defaultsKey: "actions"),
    Panel(name: "Clipboard", symbol: "doc.on.doc", glyphPath: nil, detail: "Browse macOS's clipboard history to paste something you copied earlier.", spotlightKey: CGKeyCode(kVK_ANSI_4), defaultsKey: "clipboard"),
    Panel(name: "System Settings", symbol: "gear", glyphPath: nil, detail: "Open System Settings — with Smart Toggle, press again to return to where you were.", spotlightKey: 0, defaultsKey: "settings"),
    Panel(name: "Keep Awake", symbol: "cup.and.saucer.fill", glyphPath: nil, detail: "Stop your Mac sleeping; a cup shows in the menu bar while it's on.", spotlightKey: 0, defaultsKey: "keepawake"),
    Panel(name: "Text Capture", symbol: "text.viewfinder", glyphPath: nil, detail: "Select a region of the screen and its text is recognized and copied.", spotlightKey: 0, defaultsKey: "textcapture"),
    Panel(name: "Color Picker", symbol: "eyedropper", glyphPath: nil, detail: "Sample the color under your cursor and copy its code in the format you choose.", spotlightKey: 0, defaultsKey: "colorpicker"),
    Panel(name: "Color History", symbol: "paintpalette", glyphPath: nil, detail: "Your recent picks — click to copy a code, drag one out as a PNG, pin the keepers.", spotlightKey: 0, defaultsKey: "colorhistory"),
    Panel(name: "Speak Text", symbol: "text.bubble", glyphPath: nil, detail: "Mirrors macOS's own Speak selection — set it up in Accessibility settings.", spotlightKey: 0, defaultsKey: "speakclipboard"),
]

/// The long-form help each group's sheet shows: what a tool does, a couple of
/// concrete uses, and a shortcut worth starting from.
struct PanelInfo {
    let body: String
    let examples: [String]
    let suggestion: String
}

let panelInfo: [String: PanelInfo] = [
    "apps": PanelInfo(
        body: "Opens Spotlight's Applications panel — a grid of everything installed, ready to filter by name. It launches through the system's own Apps stub, so it's instant and needs no permissions.",
        examples: ["Launch an app without hunting the Dock or Launchpad.",
                   "Browse what's installed when you can't recall the name."],
        suggestion: "⌘1 — the same number Spotlight uses, now from anywhere."),
    "files": PanelInfo(
        body: "Opens Spotlight's Files panel, scoped to documents and folders — the same search, minus the apps, web results, and definitions.",
        examples: ["Jump to a document you were editing yesterday.",
                   "Find a folder buried deep without opening Finder."],
        suggestion: "⌘2 — matches its number inside Spotlight."),
    "actions": PanelInfo(
        body: "Opens Spotlight's Actions panel: Shortcuts and quick system actions you can run by name, without leaving the keyboard.",
        examples: ["Run a Shortcut you built, by typing its name.",
                   "Trigger a system action mid-task."],
        suggestion: "⌘3 — matches its number inside Spotlight."),
    "clipboard": PanelInfo(
        body: "Opens Spotlight's Clipboard panel — macOS's own clipboard history, so you can paste something you copied a while back.",
        examples: ["Recover a link you copied over an hour ago.",
                   "Grab the second-to-last thing you copied."],
        suggestion: "⌘4 — matches its number inside Spotlight."),
    "settings": PanelInfo(
        body: "Opens System Settings. With Smart Toggle on, pressing the shortcut again hides it and returns you to the app you came from — so it works like a peek rather than a detour.",
        examples: ["Check a toggle mid-task and bounce straight back.",
                   "Reach Wi-Fi or Sound without leaving the keyboard."],
        suggestion: "⌥⌘, — next to the ⌘, most apps use for preferences."),
    "colorpicker": PanelInfo(
        body: "Pops the system color loupe, then copies the pixel under your cursor as a code in the format you choose. Every pick is also saved to Color History.",
        examples: ["Lift a hex from a screenshot straight into CSS.",
                   "Match a brand color you can only see on screen."],
        suggestion: "⌃⌘C — near ⌘C, and unlikely to be taken."),
    "colorhistory": PanelInfo(
        body: "A window of the colors you've picked — click a swatch to copy its code again, drag one out to save it as a PNG, and pin the ones worth keeping. Recents roll off after 20; pins stay.",
        examples: ["Recover a color you sampled earlier this morning.",
                   "Keep a palette pinned while you design."],
        suggestion: "⌃⌘H — sits beside your Color Picker chord."),
    "textcapture": PanelInfo(
        body: "Drag a region of the screen and its text is recognized on-device and copied — a native TextSniper. Choose whether to keep the line breaks or flow it onto one line.",
        examples: ["Copy text out of a screenshot, PDF, or video.",
                   "Grab an error message that won't let you select it."],
        suggestion: "⌃⌘T — an easy chord for a frequent grab."),
    "keepawake": PanelInfo(
        body: "Holds a power assertion so your Mac won't sleep, the same mechanism caffeinate uses. A cup appears in the menu bar while it's on — click it to stop — and it releases automatically if LiteSwitch quits.",
        examples: ["Keep a long render or download alive.",
                   "Stop the screen sleeping during a presentation."],
        suggestion: "⌃⌘K — a deliberate chord for a toggle you leave on."),
    "speakclipboard": PanelInfo(
        body: "Mirrors macOS's built-in “Speak selection” rather than re-implementing it. The field shows the shortcut macOS has assigned; Set Up… opens Spoken Content, where you enable it and choose the voice.",
        examples: ["Have a long article read while you do something else.",
                   "Proofread by ear — mistakes are easier to hear."],
        suggestion: "Set in System Settings, not here."),
]

/// Panels shown in the "System Tools" group rather than the "Spotlight" group,
/// and — like Applications — driven without needing Accessibility.
let utilityKeys: Set<String> = ["settings", "colorpicker", "colorhistory", "textcapture", "keepawake", "speakclipboard"]
func isUtility(_ panel: Panel) -> Bool { utilityKeys.contains(panel.defaultsKey) }
/// Rows of option controls a card shows below its shortcut field: every System
/// Tool has one (a checkbox or select menu); Spotlight panels have none.
func optionRows(_ panel: Panel) -> Int { isUtility(panel) ? 1 : 0 }
/// Panels that work without Accessibility (no keystroke synthesis).
func worksWithoutAX(_ panel: Panel) -> Bool {
    ["apps", "colorpicker", "colorhistory", "textcapture", "keepawake"].contains(panel.defaultsKey)
}
/// Speak Text owns no LiteSwitch shortcut — it mirrors macOS's built-in "Speak
/// selection" hotkey — so it registers nothing and its card shows a read-only
/// field plus a button into Spoken Content settings.
func mirrorsMacOSHotkey(_ panel: Panel) -> Bool { panel.defaultsKey == "speakclipboard" }

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
    /// Keep Awake: let the display sleep while the system stays awake.
    var keepAwakeAllowDisplaySleep: Bool {
        get { object(forKey: "keepAwakeAllowDisplaySleep") as? Bool ?? false }
        set { set(newValue, forKey: "keepAwakeAllowDisplaySleep") }
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

// MARK: - Color history

/// A remembered color: an sRGB hex plus whether it's a pinned keeper.
struct ColorEntry: Equatable {
    var hex: String
    var pinned: Bool
    var color: NSColor { NSColor.fromSrgbHex(hex) ?? .gray }
}

/// The Color History store — the last `maxRecent` picks plus any pinned keepers,
/// persisted in UserDefaults. Every color pick records here (fast picker too).
enum ColorHistory {
    private static let key = "colorHistory"
    static let maxRecent = 20

    static func load() -> [ColorEntry] {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return arr.compactMap {
            guard let hex = $0["hex"] as? String else { return nil }
            return ColorEntry(hex: hex, pinned: ($0["pinned"] as? Bool) ?? false)
        }
    }

    private static func save(_ entries: [ColorEntry]) {
        UserDefaults.standard.set(entries.map { ["hex": $0.hex, "pinned": $0.pinned] }, forKey: key)
    }

    /// Record a pick: it lands at the END (newest last). An existing unpinned
    /// match is refreshed to the end; a pinned match is left where it is. Then the
    /// oldest unpinned beyond the cap are evicted. Pinned entries stay grouped at
    /// the front, so the display reads pinned-first, then recents oldest→newest.
    static func add(_ color: NSColor) {
        let hex = color.srgbHexString
        var entries = load()
        if let i = entries.firstIndex(where: { $0.hex == hex }) {
            if !entries[i].pinned { entries.append(entries.remove(at: i)) }
        } else {
            entries.append(ColorEntry(hex: hex, pinned: false))
        }
        while entries.filter({ !$0.pinned }).count > maxRecent,
              let i = entries.firstIndex(where: { !$0.pinned }) {
            entries.remove(at: i)
        }
        save(entries)
    }

    /// Pinning moves a color to the TOP; unpinning drops it to the bottom as a
    /// fresh recent — keeping pinned entries grouped above the recents.
    static func togglePin(_ hex: String) {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.hex == hex }) else { return }
        var e = entries.remove(at: i)
        e.pinned.toggle()
        if e.pinned { entries.insert(e, at: 0) } else { entries.append(e) }
        save(entries)
    }

    /// Clear the unpinned recents; pinned keepers stay.
    static func clearRecents() { save(load().filter { $0.pinned }) }
}

extension NSColor {
    /// "#RRGGBB" in sRGB — the canonical form Color History stores.
    var srgbHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
    static func fromSrgbHex(_ hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Render a swatch of `color` to PNG — the image you get by dragging a color out
/// of the palette. Deliberately a full-bleed OPAQUE square: rounded corners would
/// leave transparent gaps, which Finder and Quick Look back with white, so the
/// file reads as a color chip stuck on a white card.
enum ColorSwatch {
    static func png(_ color: NSColor, px: Int = 256) -> Data? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        // Draw straight into an sRGB context: a deviceRGB bitmap color-converts
        // the fill (a #117AF9 pick exported as #0690FA), and CoreGraphics can't
        // back a 24-bit context at all (that renders black) — so use 32-bit with
        // the alpha channel skipped, filled edge to edge. Fully opaque means no
        // transparency for Finder/Quick Look to back with white.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: rgb.redComponent, green: rgb.greenComponent,
                         blue: rgb.blueComponent, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Color naming for the palette: each color shows its hex unless the user types
/// a custom name. Custom names are stored by hex, so they survive a color rolling
/// out of history and coming back.
enum ColorNames {
    private static let customKey = "colorNames"   // [hex: custom name]

    static func custom(_ hex: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: customKey) as? [String: String])?[hex]
    }
    static func setCustom(_ hex: String, _ name: String?) {
        var d = (UserDefaults.standard.dictionary(forKey: customKey) as? [String: String]) ?? [:]
        d[hex] = (name?.isEmpty == false) ? name : nil
        UserDefaults.standard.set(d, forKey: customKey)
    }
    /// The shown name: a custom one if set, else the hex itself.
    static func display(_ hex: String) -> String { custom(hex) ?? hex }
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

    /// "⌃ ⌥ ⇧ ⌘ X" for display — Apple's modifier order, glyphs spaced like the
    /// macOS menu bar (a plain space between each). No "+": that's the
    /// Windows/text convention; native macOS uses bare glyphs.
    var label: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Shortcut.keyName(keyCode))
        return parts.joined(separator: " ")
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

/// A read-only view of macOS's built-in "Speak selection" hotkey (System
/// Settings → Accessibility → Spoken Content). LiteSwitch doesn't own this
/// shortcut; the Speak Text card only reflects whatever macOS has assigned.
struct SpokenSelection: Equatable {
    let enabled: Bool
    let shortcut: String?   // e.g. "⌘⎋"; nil when no combo is stored

    static var current: SpokenSelection {
        let d = UserDefaults(suiteName: "com.apple.speech.synthesis.general.prefs")
        let enabled = d?.bool(forKey: "SpokenUIUseSpeakingHotKeyFlag") ?? false
        let combo = (d?.object(forKey: "SpokenUIUseSpeakingHotKeyCombo") as? NSNumber)?.intValue
        return SpokenSelection(enabled: enabled, shortcut: combo.map(describe))
    }

    /// The combo integer is exactly LiteSwitch's own Shortcut layout — Carbon
    /// modifier masks OR'd onto the virtual key code (cmdKey 0x100, shiftKey
    /// 0x200, optionKey 0x800, controlKey 0x1000) — so build a Shortcut and reuse
    /// its label, keeping one formatter. e.g. 4149 = 0x1035 → ⌃ esc.
    private static func describe(_ combo: Int) -> String {
        Shortcut(keyCode: UInt32(combo & 0xFF),
                 modifiers: UInt32(combo & (cmdKey | shiftKey | optionKey | controlKey))).label
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var idToPanel: [UInt32: Int] = [:]   // EventHotKeyID.id → panel index
    private var hotKeyHandler: EventHandlerRef?
    private var settings: SettingsWindow?
    private var colorHistoryPanel: ColorHistoryPanel?
    private let hud = HUD()
    private var keepAwakeAssertion: IOPMAssertionID = 0
    private var keepAwakeStatusItem: NSStatusItem?
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
        // Tooltips here are quick labels, not asides — show them promptly rather
        // than after AppKit's ~1.5 s dwell.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])
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
            if mirrorsMacOSHotkey(panel) { continue }   // macOS owns Speak Text's hotkey
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

        if panel.defaultsKey == "colorhistory" {
            showColorHistory()
            return
        }

        if panel.defaultsKey == "textcapture" {
            captureText()
            return
        }

        if panel.defaultsKey == "keepawake" {
            toggleKeepAwake()
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

    /// Show the system color loupe (`NSColorSampler`), copy the picked color's
    /// code (the clipboard is text-only by design — see `copyColorCode`), and
    /// record it to Color History (which any open palette then refreshes). The
    /// sampler reads the screen out of process (no Screen Recording /
    /// Accessibility). A nil color (Esc) leaves everything untouched.
    ///
    /// `reopenHistory` is for picks started from the palette: it closes itself
    /// first (so it never floats while the loupe is up), and this brings it back
    /// once the pick finishes — including a cancelled one.
    func sampleColor(reopenHistory: Bool = false) {
        NSColorSampler().show { [weak self] color in
            guard let self else { return }
            defer {
                if reopenHistory {
                    DispatchQueue.main.async { [weak self] in self?.openColorHistory() }
                }
            }
            guard let color else { return }
            let rgb = color.usingColorSpace(.sRGB) ?? color
            self.copyColorCode(rgb)
            ColorHistory.add(rgb)
            self.colorHistoryPanel?.reload()
        }
    }

    /// Copy a color's code (in the chosen format) to the clipboard, plus the raw
    /// `NSColor` for color wells, and flash the confirmation pill. Text + color
    /// only, no swatch image: macOS's clipboard history snapshots any image and
    /// re-offers it as a file URL on recall, so a swatch would make recalling a
    /// color paste a PATH instead of the code. (Color History is how you see past
    /// colors visually instead.)
    func copyColorCode(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let code = UserDefaults.standard.colorFormat.string(for: rgb)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        let colorType = NSPasteboard.PasteboardType(rawValue: "com.apple.cocoa.pasteboard.color")
        if let colorData = rgb.pasteboardPropertyList(forType: colorType) as? Data {
            item.setData(colorData, forType: colorType)
        }
        pb.writeObjects([item])
        hud.showColor(code: code, color: rgb)
    }

    /// Toggle the floating Color History palette (the shortcut's action).
    func showColorHistory() {
        if let p = colorHistoryPanel, p.isVisible { p.close() } else { openColorHistory() }
    }

    /// Open (never toggle) the palette — used when reopening after a pick.
    func openColorHistory() {
        if colorHistoryPanel == nil { colorHistoryPanel = ColorHistoryPanel(appDelegate: self) }
        colorHistoryPanel?.reload()
        colorHistoryPanel?.center()
        NSApp.activate(ignoringOtherApps: true)
        colorHistoryPanel?.makeKeyAndOrderFront(nil)
    }

    /// Clear the recent colors (called from the settings card); pins are kept.
    func clearColorHistory() { ColorHistory.clearRecents(); colorHistoryPanel?.reload() }

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

    /// Toggle a power assertion that blocks sleep (what `caffeinate` does). Its
    /// type depends on the "Screen Sleep" option: keep the whole system awake,
    /// or keep it awake but still let the display sleep. Released automatically
    /// if LiteSwitch quits, so it can never orphan. No permission needed.
    @objc func toggleKeepAwake() {
        if keepAwakeAssertion != 0 {
            IOPMAssertionRelease(keepAwakeAssertion)
            keepAwakeAssertion = 0
        } else {
            createKeepAwakeAssertion()
        }
        let on = keepAwakeAssertion != 0
        updateKeepAwakeIndicator()
        hud.showMessage(on ? "Keep Awake On" : "Keep Awake Off", symbol: "cup.and.saucer.fill",
                        tint: on ? .systemGreen : .secondaryLabelColor)
    }

    /// Re-create the assertion with the current type if Keep Awake is on — used
    /// when the "Screen Sleep" option is toggled while it's running.
    func reapplyKeepAwake() {
        guard keepAwakeAssertion != 0 else { return }
        IOPMAssertionRelease(keepAwakeAssertion)
        keepAwakeAssertion = 0
        createKeepAwakeAssertion()
    }

    private func createKeepAwakeAssertion() {
        let type = UserDefaults.standard.keepAwakeAllowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep    // system awake, display may sleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep   // display stays awake too
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "LiteSwitch Keep Awake" as CFString, &id) == kIOReturnSuccess {
            keepAwakeAssertion = id
        }
    }

    /// A menu-bar cup that appears only while Keep Awake is on (LiteSwitch is
    /// otherwise menu-bar-less) — a persistent indicator, click it to turn off.
    private func updateKeepAwakeIndicator() {
        if keepAwakeAssertion != 0 {
            guard keepAwakeStatusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let img = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keep Awake")
            img?.isTemplate = true
            item.button?.image = img
            item.button?.toolTip = "LiteSwitch Keep Awake is on — click to turn off"
            item.button?.target = self
            item.button?.action = #selector(toggleKeepAwake)
            keepAwakeStatusItem = item
        } else if let item = keepAwakeStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            keepAwakeStatusItem = nil
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
        // Spotlight reopens holding — and selecting — your last query, so a bare
        // Delete lands on that selection and empties the field. Deliberately NOT
        // ⌘A + Delete: if this sequence ever misfires into the frontmost app
        // (Spotlight was already open, so ⌘Space closed it), select-all + delete
        // would wipe that app's document. A stray Delete costs one character.
        DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.12) { [weak self] in
            self?.post(CGKeyCode(kVK_Delete), [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.3) { [weak self] in
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
        x.toolTip = toolTip
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

/// Top-down coordinates, so scrolled help content starts at the top.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SettingsWindow: NSWindow, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var banner: NSTextField?

    // Layout constants — the panels sit side by side, each in its own box.
    private let pad: CGFloat = 20
    // Vertical rhythm mirrored from Key54's settings window: a tall margin
    // under the transparent titlebar, fixed title/switch/description gaps, one
    // consistent section gap before and after the box row, and a Key54-sized
    // button bar.
    private let topMargin: CGFloat = 44
    private let titleTextH: CGFloat = 33
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
    // Grouping: Spotlight panels in one titled outline box, System Tools in a
    // second one (same width) stacked below, its cards wrapping into rows.
    private let groupTitleH: CGFloat = 18, groupTitleGap: CGFloat = 6
    private let groupPad: CGFloat = 12, utilRowGap: CGFloat = 12
    private func groupWidth(_ w: CGFloat, _ count: Int) -> CGFloat {
        groupPad * 2 + w * CGFloat(count) + boxGap * CGFloat(count - 1)
    }
    private var group1W: CGFloat { groupWidth(boxW, spotlightPanels.count) }
    // The window is as wide as the Spotlight group; the System Tools box matches.
    private var winW: CGFloat { pad * 2 + group1W }
    private var contentW: CGFloat { winW - pad * 2 }
    // How the System Tools cards wrap: as many per row as fit the box width,
    // split into balanced rows (e.g. 5 tools → 3 + 2).
    private var utilPerRowMax: Int { max(1, Int((group1W - groupPad * 2 + boxGap) / (boxW + boxGap))) }
    private var utilRowCount: Int {
        let n = utilityPanels.count
        return max(1, (n + utilPerRowMax - 1) / utilPerRowMax)
    }
    private var utilPerRow: Int {
        let n = utilityPanels.count
        return max(1, (n + utilRowCount - 1) / utilRowCount)
    }
    private var spotlightPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { !isUtility($0.element) }.map { ($0.offset, $0.element) }
    }
    private var utilityPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { isUtility($0.element) }.map { ($0.offset, $0.element) }
    }
    /// Permission / Spoken Content state the current content was built for, so
    /// returning from System Settings rebuilds (and re-lights the strip) when any
    /// of them changed.
    private var builtWithAX = true
    private var builtScreenRec = CGPreflightScreenCaptureAccess()
    private var builtSpoken = SpokenSelection.current
    /// Group keys whose help overlay is currently covering their box.
    private var helpShown: Set<String> = []

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
        let utilGroupBoxH = groupPad * 2 + CGFloat(utilRowCount) * utilCardH
                          + CGFloat(utilRowCount - 1) * utilRowGap
        let spotGroupH = groupTitleH + groupTitleGap + spotGroupBoxH
        let utilGroupH = groupTitleH + groupTitleGap + utilGroupBoxH
        let groupsH = spotGroupH + sectionGap + utilGroupH   // stacked, gap between

        // Both permissions just light the bottom strip; neither blocks the
        // controls — macOS prompts for each on demand when a shortcut first
        // needs it (Accessibility for the synthesized panels, Screen Recording
        // the first time Text Capture runs).
        let hasAX = appDelegate?.hasAccessibility ?? AXIsProcessTrusted()
        let hasScreenRec = CGPreflightScreenCaptureAccess()
        builtWithAX = hasAX
        builtScreenRec = hasScreenRec
        builtSpoken = SpokenSelection.current

        let switchBlockH = titleSwitchGap + switchRowH + unitGap + descH
        let hdrH = topMargin + titleTextH + switchBlockH + sectionGap
        let H = hdrH + groupsH + footerH
        let keepTop: CGFloat? = isVisible ? frame.maxY : nil
        setContentSize(NSSize(width: winW, height: H))
        if let top = keepTop { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }

        let v = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: H))

        let enabled = appDelegate?.appEnabled ?? true
        var yTop = H - topMargin

        yTop -= titleTextH
        let titleLabel = NSTextField(labelWithString: "LiteSwitch")
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: pad, y: yTop, width: winW - pad * 2, height: titleTextH)
        v.addSubview(titleLabel)

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
        let switchTip = enabled
            ? "LiteSwitch is on: your shortcuts are live and it starts automatically at login. Switching off releases the shortcuts and stops it launching at login — unlike Quit, which only ends this session."
            : "LiteSwitch is off: no shortcuts fire and it won't start at login. Switch on to restore both."
        capLabel.toolTip = switchTip
        sw.toolTip = switchTip
        capLabel.frame = NSRect(x: groupX, y: yTop + (switchRowH - capH) / 2, width: capW, height: capH)
        v.addSubview(capLabel)
        sw.frame = NSRect(x: groupX + capW + swGap, y: yTop + (switchRowH - swH) / 2, width: swW, height: swH)
        v.addSubview(sw)

        yTop -= unitGap + descH
        addPermissionPill(hasAX: hasAX, hasScreenRec: hasScreenRec, rowY: yTop, rowH: descH, in: v)

        let onChange: () -> Void = { [weak self] in self?.appDelegate?.syncHotkeys(); self?.rebuild() }
        let contentTop = H - hdrH

        // ── Two titled outlines, stacked: Spotlight Panels over System Tools ──
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

            v.addSubview(icon)

            let name = NSTextField(labelWithString: panel.name)
            // A name too wide for the fixed card ("System Settings") steps down a
            // point or two rather than truncating.
            var titleSize: CGFloat = 13
            while titleSize > 10,
                  (panel.name as NSString).size(withAttributes: [
                      .font: NSFont.systemFont(ofSize: titleSize, weight: .semibold)]).width > colW {
                titleSize -= 0.5
            }
            name.font = .systemFont(ofSize: titleSize, weight: .semibold)
            name.alignment = .center
            name.textColor = enabled ? .labelColor : .tertiaryLabelColor
            name.frame = NSRect(x: cx, y: top - iconSize - 21, width: colW, height: 17)
            v.addSubview(name)

            var lineTop = top - headerBlockH

            if mirrorsMacOSHotkey(panel) {
                // Read-only mirror of the macOS "Speak selection" shortcut, in the
                // same rounded field style as the other cards — but dimmed on
                // purpose: unlike the editable recorders it's set in Spoken Content
                // (the Set Up… button), and the dim makes "not editable here" read
                // at a glance.
                let spoken = SpokenSelection.current
                let readout = NSButton(title: spoken.enabled ? (spoken.shortcut ?? "On") : "Not Set Up",
                                       target: nil, action: nil)
                readout.bezelStyle = .rounded
                readout.font = .systemFont(ofSize: 11)
                readout.alignment = .center
                readout.isEnabled = false          // display only — macOS owns this shortcut
                readout.frame = NSRect(x: cx, y: lineTop - itemH, width: colW, height: itemH)
                v.addSubview(readout)
            } else {
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
            }
            lineTop -= (itemH + itemGap)

            // Tool option below the shortcut. Settings and Text Capture use a
            // checkbox; Color Picker uses a select menu (its copy format).
            func centeredCheckbox(_ title: String, on: Bool, action: Selector) {
                let check = NSButton(checkboxWithTitle: title, target: self, action: action)
                check.state = on ? .on : .off
                check.isEnabled = enabled
                check.font = .systemFont(ofSize: 11)
                check.sizeToFit()
                let w = ceil(check.frame.width)
                check.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(check)
            }
            if panel.defaultsKey == "settings" {
                centeredCheckbox("Smart Toggle", on: UserDefaults.standard.settingsToggle,
                                 action: #selector(smartToggleChanged(_:)))
            }
            if panel.defaultsKey == "textcapture" {
                centeredCheckbox("Remove Breaks", on: !UserDefaults.standard.ocrKeepLineBreaks,
                                 action: #selector(removeBreaksChanged(_:)))
            }
            if panel.defaultsKey == "keepawake" {
                centeredCheckbox("Screen Sleep", on: UserDefaults.standard.keepAwakeAllowDisplaySleep,
                                 action: #selector(screenSleepChanged(_:)))
            }
            if panel.defaultsKey == "colorhistory" {
                let btn = NSButton(title: "Clear", target: self, action: #selector(clearColorHistoryTapped))
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 11)
                btn.isEnabled = enabled
                btn.sizeToFit()
                let w = ceil(btn.frame.width)
                btn.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(btn)
            }
            if panel.defaultsKey == "speakclipboard" {
                // One job — open Spoken Content — but the label tracks state:
                // "Set Up…" when the feature is off, "Change…" once it's on.
                // (macOS won't let an app arm that hotkey itself, so enabling
                // stays a one-click job for the user there.)
                let btn = NSButton(title: SpokenSelection.current.enabled ? "Change…" : "Set Up…",
                                   target: self, action: #selector(openSpokenContent))
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 11)
                btn.isEnabled = enabled
                btn.sizeToFit()
                let w = ceil(btn.frame.width)
                btn.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(btn)
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
        addGroupHelp(key: "spotlight", title: "Spotlight Panels", box: g1Box, titleTop: contentTop,
                     entries: spotlightPanels, dimmed: !enabled, in: v)

        // System Tools — same width as Spotlight, cards wrapped into balanced,
        // centered rows so the group grows down as tools are added.
        let g2Top = contentTop - spotGroupH - sectionGap
        let g2Box = addGroup("System Tools", x: pad, width: group1W,
                             top: g2Top, boxH: utilGroupBoxH, dimmed: !enabled, in: v)
        let utilTop = g2Box.maxY - groupPad
        for (i, entry) in utilityPanels.enumerated() {
            let row = i / utilPerRow
            let posInRow = i % utilPerRow
            let cardsInRow = min(utilPerRow, utilityPanels.count - row * utilPerRow)
            let clusterW = CGFloat(cardsInRow) * boxW + CGFloat(cardsInRow - 1) * boxGap
            let startX = g2Box.minX + (group1W - clusterW) / 2
            layoutCard(entry.index, entry.panel,
                       cardX: startX + CGFloat(posInRow) * (boxW + boxGap),
                       cardTop: utilTop - CGFloat(row) * (utilCardH + utilRowGap),
                       cardH: utilCardH)
        }
        addGroupHelp(key: "utilities", title: "System Tools", box: g2Box, titleTop: g2Top,
                     entries: utilityPanels, dimmed: !enabled, in: v)

        // Footer: the conflict banner across the top, Quit (left) + Done (right).
        let bannerField = NSTextField(wrappingLabelWithString: "")
        bannerField.font = .systemFont(ofSize: 11)
        bannerField.textColor = .systemOrange
        bannerField.alignment = .center
        bannerField.frame = NSRect(x: pad, y: bottomMargin + btnH + 8, width: winW - pad * 2, height: 20)
        v.addSubview(bannerField)
        banner = bannerField

        let quit = NSButton(title: "Quit", target: self, action: #selector(forceQuit))
        quit.bezelStyle = .rounded
        quit.contentTintColor = .systemRed
        quit.toolTip = "Quit LiteSwitch for now. It still starts at login — use the switch above to stop that too."
        quit.frame = NSRect(x: pad, y: bottomMargin, width: btnW, height: btnH)
        v.addSubview(quit)

        let done = NSButton(title: "Done", target: self, action: #selector(saveAndClose))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.toolTip = "Close this window (shortcuts are saved as you set them)."
        done.frame = NSRect(x: winW - pad - btnW, y: bottomMargin, width: btnW, height: btnH)
        v.addSubview(done)

        contentView = v
        refreshBanner()
    }

    // MARK: Layout helpers

    /// A titled outline group: small secondary label above a rounded border box.
    /// Returns the box's frame so callers can place content inside it.
    /// A ⓘ at the right end of a group's title row — it turns into a ✕ while its
    /// help sheet is up. The sheet lays over that group's box, explaining every
    /// tool in the group at once (icon, what it does, a couple of uses, and a
    /// suggested shortcut), and scrolls when there's more than fits.
    private func addGroupHelp(key: String, title: String, box: NSRect, titleTop: CGFloat,
                              entries: [(index: Int, panel: Panel)], dimmed: Bool, in v: NSView) {
        let open = helpShown.contains(key)
        let btn = NSButton(title: "", target: self, action: #selector(toggleGroupHelp(_:)))
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: open ? "xmark.circle.fill" : "info.circle",
                            accessibilityDescription: open ? "Close help" : "Help")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        btn.imagePosition = .imageOnly
        btn.contentTintColor = .secondaryLabelColor
        btn.identifier = NSUserInterfaceItemIdentifier(key)
        btn.toolTip = open ? "Hide \(title) help"
                          : "View \(title) help and documentation"
        btn.alphaValue = dimmed ? 0.5 : 1
        btn.frame = NSRect(x: box.maxX - 6 - 18, y: titleTop - groupTitleH + 1, width: 18, height: 16)
        v.addSubview(btn)

        guard open else { return }

        // The sheet: same rounded footprint as the box, so it reads as covering it.
        let sheet = NSView(frame: box)
        sheet.wantsLayer = true
        sheet.layer?.cornerRadius = 10
        sheet.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sheet.layer?.borderWidth = 1
        sheet.layer?.borderColor = NSColor.separatorColor.cgColor
        v.addSubview(sheet)

        let inset: CGFloat = 14
        let scroll = NSScrollView(frame: NSRect(x: inset, y: inset,
                                                width: box.width - inset * 2,
                                                height: box.height - inset * 2))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy          // a bar that's always visible
        sheet.addSubview(scroll)

        // One block per tool: icon, name, body, uses, suggested shortcut. The
        // document is sized to the clip width minus the always-present scroller,
        // so text wraps instead of scrolling sideways.
        let scrollerW = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let innerW = scroll.frame.width - scrollerW - 6
        let textX: CGFloat = 30, textW = innerW - textX
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: innerW, height: 10))
        var y: CGFloat = 0

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                   color: NSColor, x: CGFloat, width: CGFloat) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = color
            f.isSelectable = false
            f.preferredMaxLayoutWidth = width
            let h = ceil(f.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
            f.frame = NSRect(x: x, y: 0, width: width, height: h)
            return f
        }

        for (i, entry) in entries.enumerated() {
            if i > 0 { y += 16 }
            let panel = entry.panel
            let icon = NSImageView(frame: NSRect(x: 0, y: y, width: 22, height: 22))
            configureIcon(icon, panel, dimmed: false)
            doc.addSubview(icon)

            let name = label(panel.name, size: 12, weight: .semibold, color: .labelColor,
                             x: textX, width: textW)
            name.frame.origin.y = y + 3
            doc.addSubview(name)
            y = name.frame.maxY + 4

            let info = panelInfo[panel.defaultsKey]
            let body = label(info?.body ?? panel.detail, size: 11, weight: .regular,
                             color: .secondaryLabelColor, x: textX, width: textW)
            body.frame.origin.y = y
            doc.addSubview(body)
            y = body.frame.maxY + 5

            for example in info?.examples ?? [] {
                let line = label("•  " + example, size: 11, weight: .regular,
                                 color: .secondaryLabelColor, x: textX + 4, width: textW - 4)
                line.frame.origin.y = y
                doc.addSubview(line)
                y = line.frame.maxY + 2
            }
            if let suggestion = info?.suggestion {
                let line = label("Suggested: " + suggestion, size: 11, weight: .regular,
                                 color: .tertiaryLabelColor, x: textX, width: textW)
                line.frame.origin.y = y + 3
                doc.addSubview(line)
                y = line.frame.maxY
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: innerW, height: y)
        doc.autoresizingMask = [.width]
        scroll.documentView = doc
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
    }

    @objc private func toggleGroupHelp(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if helpShown.contains(key) { helpShown.remove(key) } else { helpShown.insert(key) }
        rebuild()
    }

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

    /// A two-tone pill under the switch, in place of a description: the leading
    /// "System Permissions:" label on one gray, the permission lights on a
    /// second gray. Each light is a green dot when granted, or a red, underlined
    /// link when not — clicking fires the real macOS request (prompting the user
    /// and adding LiteSwitch to that permission's list). Nothing here blocks the
    /// app. Sits vertically centered in the [rowY, rowY+rowH] slot.
    private func addPermissionPill(hasAX: Bool, hasScreenRec: Bool, rowY: CGFloat, rowH: CGFloat, in v: NSView) {
        let pillH: CGFloat = 22, segPad: CGFloat = 11, itemGap: CGFloat = 16
        func cy(_ h: CGFloat) -> CGFloat { (pillH - h) / 2 }

        // Leading label.
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let heading = NSTextField(labelWithString: "System Permissions:")
        heading.font = labelFont
        heading.textColor = .secondaryLabelColor
        heading.sizeToFit()
        let headW = ceil(heading.frame.width), headH = ceil(heading.frame.height)

        // dot + name; granted is plain status, missing is an underlined link.
        func item(_ name: String, granted: Bool, action: Selector, tip: String) -> NSButton {
            let title = NSMutableAttributedString(
                string: "● ", attributes: [.foregroundColor: granted ? NSColor.systemGreen : NSColor.systemRed,
                                            .font: NSFont.systemFont(ofSize: 9)])
            var nameAttrs: [NSAttributedString.Key: Any] =
                [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                 .foregroundColor: granted ? NSColor.secondaryLabelColor : NSColor.labelColor]
            if !granted { nameAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            title.append(NSAttributedString(string: name, attributes: nameAttrs))
            let btn = NSButton()
            btn.isBordered = false
            btn.attributedTitle = title
            btn.toolTip = tip
            btn.sizeToFit()
            if granted { btn.target = nil; btn.action = nil }
            else { btn.target = self; btn.action = action }
            return btn
        }

        let a = item("Accessibility", granted: hasAX, action: #selector(grantAccessibility),
                     tip: hasAX ? "Accessibility is on — the synthesized Spotlight shortcuts can run."
                                : "Lets Files, Actions, Clipboard, and the Settings shortcut work. Click to ask macOS and add LiteSwitch to the list.")
        let s = item("Screen Recording", granted: hasScreenRec, action: #selector(grantScreenRecording),
                     tip: hasScreenRec ? "Screen Recording is on — Text Capture can read the selected region."
                                       : "Lets Text Capture read the selected region. Click to ask macOS and add LiteSwitch to the list (takes effect after a relaunch).")
        let aw = ceil(a.frame.width), sw2 = ceil(s.frame.width)
        let ah = ceil(a.frame.height), sh = ceil(s.frame.height)

        // Two segments: label chip (darker gray) then the lights chip (lighter).
        let labelSegW = segPad + headW + segPad
        let lightsSegW = segPad + aw + itemGap + sw2 + segPad
        let totalW = labelSegW + lightsSegW
        let pillX = (winW - totalW) / 2
        let pillY = rowY + (rowH - pillH) / 2

        let pill = NSView(frame: NSRect(x: pillX, y: pillY, width: totalW, height: pillH))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pillH / 2
        pill.layer?.masksToBounds = true
        v.addSubview(pill)

        // Two near-identical grays (about quaternary / quinary label strength —
        // quinary has no NSColor, so approximate), resolved for the current theme.
        let base = (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            ? NSColor.white : NSColor.black
        let leftBG = NSView(frame: NSRect(x: 0, y: 0, width: labelSegW, height: pillH))
        leftBG.wantsLayer = true
        leftBG.layer?.backgroundColor = base.withAlphaComponent(0.10).cgColor
        pill.addSubview(leftBG)
        let rightBG = NSView(frame: NSRect(x: labelSegW, y: 0, width: lightsSegW, height: pillH))
        rightBG.wantsLayer = true
        rightBG.layer?.backgroundColor = base.withAlphaComponent(0.055).cgColor
        pill.addSubview(rightBG)

        heading.frame = NSRect(x: segPad, y: cy(headH), width: headW, height: headH)
        pill.addSubview(heading)
        var x = labelSegW + segPad
        a.frame = NSRect(x: x, y: cy(ah), width: aw, height: ah); pill.addSubview(a); x += aw + itemGap
        s.frame = NSRect(x: x, y: cy(sh), width: sw2, height: sh); pill.addSubview(s)
    }

    /// Fire the real macOS permission requests — each prompts the user and adds
    /// LiteSwitch to that permission's list in System Settings.
    @objc private func grantAccessibility() { appDelegate?.promptForAccessibility() }
    @objc private func grantScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    @objc private func forceQuit() { NSApp.terminate(nil) }
    @objc private func saveAndClose() { close() }
    @objc private func smartToggleChanged(_ sender: NSButton) {
        UserDefaults.standard.settingsToggle = sender.state == .on
    }

    @objc private func colorFormatChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.colorFormat = ColorFormat(rawValue: sender.indexOfSelectedItem) ?? .hex
    }

    @objc private func clearColorHistoryTapped() { appDelegate?.clearColorHistory() }

    @objc private func removeBreaksChanged(_ sender: NSButton) {
        UserDefaults.standard.ocrKeepLineBreaks = sender.state != .on   // checked = remove breaks
    }

    @objc private func screenSleepChanged(_ sender: NSButton) {
        UserDefaults.standard.keepAwakeAllowDisplaySleep = sender.state == .on
        appDelegate?.reapplyKeepAwake()   // take effect now if Keep Awake is running
    }

    @objc private func openSpokenContent() {
        let urls = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"]
        for s in urls where NSWorkspace.shared.open(URL(string: s)!) { break }
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

    /// Footer text carries only hotkey conflicts; the Accessibility state lives
    /// in the bottom strip, so a trust flip triggers a rebuild to re-light it.
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
        refreshBanner()   // rebuilds if Accessibility flipped (re-lights the strip)
        // Reflect a Screen Recording grant or a "Speak selection" change made in
        // System Settings while we were away.
        if CGPreflightScreenCaptureAccess() != builtScreenRec
            || SpokenSelection.current != builtSpoken { rebuild() }
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

// MARK: - Color history palette

/// A floating palette of recently-picked colors. A grid of swatches, each a color
/// square over an editable label box (the hex by default; click to rename).
/// Click a square to copy its code, drag it out to get the swatch as a PNG, or
/// use its hover pin to keep it. The header has an
/// eyedropper Pick, a format selector, and Clear. Recent picks roll off after 20;
/// pinned keepers persist at the top. It's an ordinary window — it stays open
/// while you work elsewhere until you close it — except that Pick closes it for
/// the duration of the sample, then reopens it.
final class ColorHistoryPanel: NSPanel, NSTextFieldDelegate {
    private weak var appDelegate: AppDelegate?
    private let cols = 5
    private let sq: CGFloat = 90                 // color square
    private let labelH: CGFloat = 20, labelGap: CGFloat = 4
    private let gap: CGFloat = 10, pad: CGFloat = 16, headerH: CGFloat = 42
    private var cellH: CGFloat { sq + labelGap + labelH }
    private var reloading = false   // guards against any re-entrant rebuild loop

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Color History"
        // A normal window, not a floating overlay: it stays put while you work in
        // other apps and closes only via its close button, so it can sit open
        // alongside a design tool.
        isFloatingPanel = false
        level = .normal
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Panels close on Esc by default; this one is an ordinary window that should
    /// only close via its close button (Esc still just ends a rename edit).
    override func cancelOperation(_ sender: Any?) {}

    /// LiteSwitch is a menu-bar-less agent, so there's no File menu to supply
    /// ⌘W — wire it up here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Rebuild the content from the current store — called on open and after any
    /// pick / pin / clear / format change.
    func reload() {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }
        let entries = ColorHistory.load()
        let fmt = UserDefaults.standard.colorFormat
        let rows = max(1, Int(ceil(Double(entries.count) / Double(cols))))
        let contentW = pad * 2 + CGFloat(cols) * sq + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        let H = headerH + gridH + pad
        setContentSize(NSSize(width: contentW, height: H))

        let v = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: H))
        let headerY = H - headerH

        // Eyedropper "Pick" (left) — closes the window FIRST, then samples, then
        // reopens (a loupe launched from under this window could end up orphaned
        // and holding the mouse system-wide).
        let pick = NSButton(title: "Pick", target: self, action: #selector(pickTapped))
        pick.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        pick.imagePosition = .imageLeading
        pick.bezelStyle = .rounded
        pick.toolTip = "Close the palette and sample a new color."
        pick.sizeToFit()
        let ph = ceil(pick.frame.height)
        pick.frame = NSRect(x: pad, y: headerY + (headerH - ph) / 2, width: ceil(pick.frame.width) + 14, height: ph)
        v.addSubview(pick)

        // Format selector (center) — drives the copy format and the labels below.
        let fmtPopup = NSPopUpButton()
        fmtPopup.addItems(withTitles: ColorFormat.allCases.map(\.label))
        fmtPopup.selectItem(at: fmt.rawValue)
        fmtPopup.target = self; fmtPopup.action = #selector(formatChanged(_:))
        fmtPopup.toolTip = "Format used when copying a code, and shown under each swatch."
        fmtPopup.sizeToFit()
        let fw = ceil(fmtPopup.frame.width), fhh = ceil(fmtPopup.frame.height)
        fmtPopup.frame = NSRect(x: (contentW - fw) / 2, y: headerY + (headerH - fhh) / 2, width: fw, height: fhh)
        v.addSubview(fmtPopup)

        // Clear (right, only if there are recents).
        if entries.contains(where: { !$0.pinned }) {
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
            clear.bezelStyle = .rounded
            clear.toolTip = "Clear the recent colors (pinned colors are kept)."
            clear.sizeToFit()
            let cw = ceil(clear.frame.width) + 12, ch = ceil(clear.frame.height)
            clear.frame = NSRect(x: contentW - pad - cw, y: headerY + (headerH - ch) / 2, width: cw, height: ch)
            v.addSubview(clear)
        }

        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No colors yet — pick one to start.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: pad, y: (H - headerH) / 2 - 10, width: contentW - pad * 2, height: 20)
            v.addSubview(empty)
        } else {
            let top = H - headerH
            for (i, entry) in entries.enumerated() {
                let r = i / cols, c = i % cols
                let x = pad + CGFloat(c) * (sq + gap)
                let squareY = top - CGFloat(r) * (cellH + gap) - sq
                let square = ColorSquare(
                    entry: entry, size: sq, code: fmt.string(for: entry.color),
                    onCopyCode: { [weak self] in self?.appDelegate?.copyColorCode(entry.color) },
                    onTogglePin: { [weak self] in ColorHistory.togglePin(entry.hex); self?.reload() })
                square.frame = NSRect(x: x, y: squareY, width: sq, height: sq)
                v.addSubview(square)

                // Editable label in a visible box (so it's clearly renamable):
                // the hex by default; clearing it (or retyping the hex) reverts.
                // The code in the chosen format is the square's tooltip.
                let name = NSTextField()
                name.stringValue = ColorNames.display(entry.hex)
                name.isEditable = true
                name.isBezeled = true
                name.bezelStyle = .roundedBezel
                name.controlSize = .small
                name.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                name.alignment = .center
                name.lineBreakMode = .byTruncatingTail
                name.delegate = self
                name.identifier = NSUserInterfaceItemIdentifier(entry.hex)
                name.toolTip = "Rename this color"
                name.frame = NSRect(x: x, y: squareY - labelGap - labelH, width: sq, height: labelH)
                v.addSubview(name)
            }
        }
        contentView = v
        // Don't let AppKit hand first-responder to the first name field — the
        // window would open with a swatch's label focused and selected blue.
        initialFirstResponder = v
        makeFirstResponder(nil)
    }

    /// Close the palette, sample on the next runloop pass (the loupe must not be
    /// launched while this floating panel is up), then reopen once the pick ends.
    @objc private func pickTapped() {
        close()
        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.sampleColor(reopenHistory: true)
        }
    }

    @objc private func clearTapped() { ColorHistory.clearRecents(); reload() }
    @objc private func formatChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.colorFormat = ColorFormat(rawValue: sender.indexOfSelectedItem) ?? .hex
        reload()
    }

    /// Save a typed name as a custom name for that color; empty or the auto-name
    /// reverts to the auto-generated one.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let hex = field.identifier?.rawValue else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ColorNames.setCustom(hex, (typed.isEmpty || typed == hex) ? nil : typed)
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }
}

/// A borderless icon button that reports its own hover, so the pin can swap
/// between "pin.fill" and "pin.slash.fill" while the pointer is over it.
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One color square in the palette. Click it to copy its code; DRAG it out to get
/// the swatch as a PNG (into a folder, a doc, anywhere that takes an image); and
/// use the pin at its top-right to keep it: the pin appears hollow on hover, turns
/// solid and stays visible once pinned, and shows a slash on hover when pinned to
/// signal that clicking removes it. The full code is the square's tooltip.
final class ColorSquare: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private let entry: ColorEntry
    private let onCopyCode: () -> Void
    private let onTogglePin: () -> Void
    private let pin = HoverButton()
    private var tracking: NSTrackingArea?
    private var hovered = false, pinHovered = false
    private var mouseDownAt: NSPoint?
    private var dragged = false
    private let promiseQueue = OperationQueue()

    init(entry: ColorEntry, size: CGFloat, code: String,
         onCopyCode: @escaping () -> Void, onTogglePin: @escaping () -> Void) {
        self.entry = entry
        self.onCopyCode = onCopyCode; self.onTogglePin = onTogglePin
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = (entry.color.usingColorSpace(.sRGB) ?? entry.color).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        toolTip = code

        pin.isBordered = true
        pin.bezelStyle = .circular
        pin.contentTintColor = ColorSquare.contrastInk(entry.color)
        pin.target = self
        pin.action = #selector(togglePin)
        pin.frame = NSRect(x: size - 26, y: size - 26, width: 20, height: 20)
        pin.onHover = { [weak self] inside in
            self?.pinHovered = inside
            self?.updatePin()
        }
        addSubview(pin)
        updatePin()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Unpinned: hollow pin, shown only while the square is hovered. Pinned: solid
    /// pin, always shown — and a slashed pin while the pointer is on it, so it's
    /// clear a click will unpin.
    private func updatePin() {
        let pinned = entry.pinned
        pin.isHidden = !pinned && !hovered
        let sym = pinned ? (pinHovered ? "pin.slash.fill" : "pin.fill") : "pin"
        pin.image = NSImage(systemSymbolName: sym, accessibilityDescription: pinned ? "Unpin" : "Pin")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        pin.toolTip = pinned ? "Unpin this color" : "Pin this color to keep it"
    }

    @objc private func togglePin() { onTogglePin() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updatePin() }
    override func mouseExited(with event: NSEvent) { hovered = false; updatePin() }

    // Click = copy the code; drag = pull the swatch out as a PNG. The copy fires
    // on mouse-up only if no drag started, so dragging never also copies.
    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = mouseDownAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }   // real drag, not a jittery click
        dragged = true

        // A file promise, so it can be dropped into Finder as <hex>.png as well as
        // into apps that take image data.
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let preview = NSImage(size: bounds.size)
        preview.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 12, yRadius: 12)
        (entry.color.usingColorSpace(.sRGB) ?? entry.color).setFill()
        path.fill()
        preview.unlockFocus()
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onCopyCode() }
        mouseDownAt = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    // MARK: File promise (the dragged-out PNG)

    /// Name the dragged-out file after the swatch's label — its custom name if it
    /// has one, otherwise the hex (with the "#" kept). Only characters a filename
    /// can't hold are swapped out.
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String {
        let label = ColorNames.display(entry.hex)
        let safe = label.replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: ":", with: "-")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? entry.hex : safe) + ".png"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let png = ColorSwatch.png(entry.color) else { completionHandler(nil); return }
            try png.write(to: url)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    /// Black on light colors, white on dark — for the pin badge.
    static func contrastInk(_ color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? .black : .white
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
