// Liteswitch — flip any Spotlight panel on from anywhere.
//
// Liteswitch gives every Spotlight panel its own keyboard shortcut.
//
// macOS 26 gave Spotlight four panels — Apps ⌘1, Files ⌘2, Actions ⌘3,
// Clipboard ⌘4 — reachable only after opening Spotlight itself. Liteswitch lets
// you assign a global shortcut to each panel directly.
//
// How panels open:
//   • Apps      — launches the system stub /System/Applications/Apps.app
//                 (public API, no permissions, works even if ⌘Space is
//                 remapped). Falls back to synthesis if the stub is missing.
//   • Files / Actions / Clipboard — synthesizes ⌘Space then ⌘2/⌘3/⌘4, the
//                 documented gesture. Needs Accessibility to post keystrokes.
//
// A group of "System Utilities" ride alongside the panels, none needing any
// permission: open System Settings (with a smart toggle back); a Color Picker
// (NSColorSampler → clipboard); Capture Text (screencapture -i region → Vision
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
import FoundationModels

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
    Panel(name: "Applications", symbol: "square.grid.2x2", glyphPath: sidebarApplications, detail: "Every app you have installed, in a grid you can filter by name.", spotlightKey: CGKeyCode(kVK_ANSI_1), defaultsKey: "apps"),
    Panel(name: "Files", symbol: "folder", glyphPath: nil, detail: "Search your files and folders. No app or web results in the way.", spotlightKey: CGKeyCode(kVK_ANSI_2), defaultsKey: "files"),
    Panel(name: "Actions", symbol: "square.2.layers.3d", glyphPath: nil, detail: "Run a Shortcut or a system action by typing its name.", spotlightKey: CGKeyCode(kVK_ANSI_3), defaultsKey: "actions"),
    Panel(name: "Clipboard", symbol: "doc.on.doc", glyphPath: nil, detail: "Paste something you copied a while back, from macOS's own history.", spotlightKey: CGKeyCode(kVK_ANSI_4), defaultsKey: "clipboard"),
    Panel(name: "System Settings", symbol: "gear", glyphPath: nil, detail: "Open System Settings. With Smart Toggle, press again to land back where you were.", spotlightKey: 0, defaultsKey: "settings"),
    Panel(name: "Keep Awake", symbol: "cup.and.saucer.fill", glyphPath: nil, detail: "Keep your Mac awake. A cup sits in the menu bar while it's on.", spotlightKey: 0, defaultsKey: "keepawake"),
    Panel(name: "Color Picker", symbol: "eyedropper", glyphPath: nil, detail: "Grab the color under your cursor and copy it in whatever format you like.", spotlightKey: 0, defaultsKey: "colorpicker"),
    Panel(name: "Color History", symbol: "paintpalette", glyphPath: nil, detail: "Every color you've picked. Click to copy, drag one out as a PNG, pin the keepers.", spotlightKey: 0, defaultsKey: "colorhistory"),
    Panel(name: "Speak Text", symbol: "text.bubble", glyphPath: nil, detail: "Your Mac can read text aloud. This shows you how to switch it on.", spotlightKey: 0, defaultsKey: "speakclipboard"),
    Panel(name: "Capture Text", symbol: "text.viewfinder", glyphPath: nil, detail: "Drag a box around anything on screen and get its text on your clipboard.", spotlightKey: 0, defaultsKey: "textcapture"),
    Panel(name: "Correct Text", symbol: "text.badge.checkmark", glyphPath: nil, detail: "Fix spelling, grammar and punctuation with Apple Intelligence, right on your Mac.", spotlightKey: 0, defaultsKey: "polish"),
    Panel(name: "Dictate Text", symbol: "waveform.badge.microphone", glyphPath: nil, detail: "Hold a key and talk. Let go and it stops. That's the part macOS leaves out.", spotlightKey: 0, defaultsKey: "dictation"),
]

/// The long-form help each group's sheet shows: what a tool does, a couple of
/// concrete uses, and a shortcut worth starting from.
struct PanelInfo {
    let body: String
    let examples: [String]
}

let panelInfo: [String: PanelInfo] = [
    "apps": PanelInfo(
        body: "Spotlight's Applications panel — every app you have, filtered by name. It opens through a system stub rather than faked keystrokes, so it's instant and needs no permissions at all.",
        examples: ["Launch an app without hunting the Dock or Launchpad.",
                   "Browse what's installed when the name won't come to you."]),
    "files": PanelInfo(
        body: "Spotlight's Files panel searches the same index Finder does, but only documents and folders. No apps, no web results, nothing else in the way.",
        examples: ["Jump to a document you had open yesterday.",
                   "Open a folder buried deep without walking Finder down to it."]),
    "actions": PanelInfo(
        body: "Every Shortcut you've built, plus macOS's own quick actions, run by typing a name. It's the closest thing your Mac has to a command palette.",
        examples: ["Run a Shortcut by name instead of finding it in the app.",
                   "Fire off a system action in the middle of something else."]),
    "clipboard": PanelInfo(
        body: "Your Mac keeps a clipboard history of its own. This opens it, so you can paste something from a while back. Nothing extra to install or leave running.",
        examples: ["Recover a link you copied an hour ago.",
                   "Grab the second-to-last thing you copied, without redoing the work."]),
    "settings": PanelInfo(
        body: "Opens System Settings from wherever you are. With Smart Toggle on, pressing the shortcut again hides it and drops you back where you were.",
        examples: ["Flip a toggle mid-task and land straight back where you were.",
                   "Reach Wi-Fi, Sound or Displays without touching the menu bar."]),
    "colorpicker": PanelInfo(
        body: "Brings up the system loupe and copies the pixel you click, as Hex, RGB, HSL or SwiftUI. Apple's own process does the sampling, so it needs no Screen Recording. Every pick is saved to Color History.",
        examples: ["Lift a hex out of a screenshot and straight into CSS.",
                   "Match a brand color you can only see on screen."]),
    "colorhistory": PanelInfo(
        body: "Every color you've picked, in one window. Click a swatch to copy it again, drag one out as a PNG, or pin the keepers. It holds the last 20.",
        examples: ["Recover a color you sampled earlier without picking it again.",
                   "Keep a palette pinned beside you while you design."]),
    "keepawake": PanelInfo(
        body: "Stops your Mac going to sleep on its own. Turn on Screen Sleep and the display still goes dark while everything else keeps running, which saves power and rests the screen. A cup in the menu bar turns it all off.",
        examples: ["Keep a long render, download or backup alive.",
                   "Stop the screen sleeping halfway through a presentation."]),
    "textcapture": PanelInfo(
        body: "Drag a box around anything on screen and the text inside it lands on your clipboard. Apple's Vision framework reads it right on your Mac, so it works offline.",
        examples: ["Copy text out of a screenshot, a PDF, or a paused video.",
                   "Grab an error message from a dialog that won't let you select it."]),
    "speakclipboard": PanelInfo(
        body: "Your Mac already reads text aloud, in the same voices Siri uses. This doesn't add a second engine — it shows the shortcut macOS gave it, and Set Up… opens Spoken Content.",
        examples: ["Have a long article read to you while you do something else.",
                   "Proofread by ear — the mistakes you skim past are audible."]),
    "dictation": PanelInfo(
        body: "Hold a key, talk, let go. Your Mac does the transcribing on-device, so nothing you say leaves it. What it won't do is hold-to-talk, and that's the only thing this adds. The meter is green while listening, amber while dictation catches up, purple while Auto-Correct rewrites.",
        examples: ["Get a long reply down without typing it all out.",
                   "Talk out a rough paragraph, then correct it by hand."]),
    "polish": PanelInfo(
        body: "Fixes spelling, grammar and punctuation with Apple Intelligence, running on your Mac. It keeps two sets of instructions for two jobs: proofreading what you selected, and cleaning up dictated speech. Both are yours to edit.",
        examples: ["Clean up a paragraph you typed in a hurry, without it being reworded.",
                   "Turn a rambling dictation into something you'd actually send."]),
]

/// Panels shown in the "System Utilities" group rather than the "Spotlight" group,
/// and — like Applications — driven without needing Accessibility.
let utilityKeys: Set<String> = ["settings", "colorpicker", "colorhistory", "textcapture", "keepawake", "dictation", "speakclipboard", "polish"]
func isUtility(_ panel: Panel) -> Bool { utilityKeys.contains(panel.defaultsKey) }
/// The tools that work on text, grouped apart from the system ones — they read
/// as a set (capture it, speak it, dictate it, tidy it) and it keeps each group
/// to a single row.
let textKeys: Set<String> = ["textcapture", "speakclipboard", "dictation", "polish"]
func isTextTool(_ panel: Panel) -> Bool { textKeys.contains(panel.defaultsKey) }
/// Rows of option controls a card shows below its shortcut field: every System
/// Tool has one (a checkbox or select menu); Spotlight panels have none.
func optionRows(_ panel: Panel) -> Int { isUtility(panel) ? 1 : 0 }
/// Panels that work without Accessibility (no keystroke synthesis).
func worksWithoutAX(_ panel: Panel) -> Bool {
    ["apps", "colorpicker", "colorhistory", "textcapture", "keepawake"].contains(panel.defaultsKey)
}
/// Speak Text owns no Liteswitch shortcut — it mirrors macOS's built-in "Speak
/// selection" hotkey — so it registers nothing and its card shows a read-only
/// field plus a button into Spoken Content settings.
func mirrorsMacOSHotkey(_ panel: Panel) -> Bool { panel.defaultsKey == "speakclipboard" }

/// What a fresh install starts with: ⌃⌥⌘ plus a key under your right hand.
///
/// Three modifiers look heavy written down, but the left hand takes them as one
/// shape and never moves, which leaves every trigger key on the right — no chord
/// crosses the keyboard. It's also the one combination nothing else claims: ⌃
/// alone hits the text-editing bindings macOS puts in every field (⌃A, ⌃K, ⌃H),
/// ⌥ alone eats the character it would otherwise type, and ⌘ belongs to whatever
/// app is frontmost.
///
/// Every key earns its place. The four panels run left to right in the order
/// Spotlight numbers them. `/` finds and `\` does — mirrored symbols for paths and
/// for escapes. `,` is the preferences key every Mac app already uses. `'` is
/// quoted text. The rest are initials: Loupe, History, Keep awake, OCR.
///
/// Only ever applied to a tool with no shortcut of its own — see
/// `seedDefaultShortcutsIfNeeded`.
let defaultShortcuts: [String: UInt32] = [   // virtual key codes; all take ⌃⌥⌘
    "apps": 47,           // .        panel 1
    "files": 44,          // /        panel 2 — the path separator: finding
    "actions": 42,        // \        panel 3 — the escape: doing
    "clipboard": 9,       // V        the paste key, for the paste history
    "settings": 43,       // ,        the preferences key
    "colorpicker": 37,    // L        Loupe
    "colorhistory": 4,    // H        History
    "keepawake": 40,      // K        Keep awake
    "textcapture": 31,    // O        OCR
    "polish": 35,         // P        Proofread
]

/// Dictation is push-to-talk: it needs the key's release as well as its press,
/// which a Carbon hotkey never reports, so it watches a modifier instead of
/// registering a shortcut.
func usesHoldKey(_ panel: Panel) -> Bool { panel.defaultsKey == "dictation" }

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The modifier held down to talk. Only the right-hand ⌘ and ⌥ are offered:
/// Apple keyboards have no right Control, and Fn/Globe is claimed by the system
/// before it reaches us. Raw values are persisted — only append.
enum HoldKey: Int, CaseIterable {
    case off = 0, rightCommand = 1, rightOption = 2

    /// Menu order — deliberately not the raw order, which is fixed by what's
    /// already stored in defaults.
    static let menuOrder: [HoldKey] = [.off, .rightOption, .rightCommand]

    var label: String {
        switch self {
        case .off:           return "Off"
        case .rightCommand:  return "Hold Right ⌘"
        case .rightOption:   return "Hold Right ⌥"
        }
    }
    /// The physical key, and the flag that tells press from release.
    var keyCode: UInt16? {
        switch self {
        case .off: return nil
        case .rightCommand: return 54
        case .rightOption: return 61
        }
    }
    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .off: return nil
        case .rightCommand: return .command
        case .rightOption: return .option
        }
    }
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
    /// Capture Text: keep the OCR line breaks, or flow it onto one line.
    /// Off by default — captured text is usually wanted as prose, not with the
    /// wrapping of wherever it was scraped from.
    var ocrKeepLineBreaks: Bool {
        get { object(forKey: "ocrKeepLineBreaks") as? Bool ?? false }
        set { set(newValue, forKey: "ocrKeepLineBreaks") }
    }
    /// Keep Awake: let the display sleep while the system stays awake. On by
    /// default — the usual reason to block sleep is to let work finish, not to
    /// burn the screen.
    var keepAwakeAllowDisplaySleep: Bool {
        get { object(forKey: "keepAwakeAllowDisplaySleep") as? Bool ?? true }
        set { set(newValue, forKey: "keepAwakeAllowDisplaySleep") }
    }
    /// Correct Text: what to tell the on-device model. Two sets, because correcting
    /// text you typed and cleaning up speech are different jobs.
    /// Spelled out deliberately. "Correct spelling, grammar, capitalization and
    /// punctuation" on its own reads to this model as permission to fix only the
    /// safe, local thing — it would mend a misspelling and hand back a sentence
    /// with no capital and no full stop, and sometimes answer a question instead
    /// of correcting it. Naming the mechanics fixes both, consistently.
    ///
    /// Naming them is also as far as it should go. Three drafts that lost, so
    /// they don't get tried again:
    ///
    /// - "A question takes a question mark" put question marks on flat statements
    ///   and appended "— is that correct?".
    /// - "Leave contractions as they are" changed nothing whatsoever.
    /// - Spelling the contractions out ("dont becomes don't") did work — and cost
    ///   grammar to get it. Over 12 samples against 12 for this wording, it fixed
    ///   the grammar in 9 rather than 11, left "We was" and "it don't" standing,
    ///   and reordered "him and me" into "I and him" three times, which this very
    ///   instruction forbids. Leaving "it's" as "it is" is a style nit; leaving
    ///   "we was" is a failure to do the job, so the nit stays.
    ///
    /// Simpler wordings lose differently. "Fix spelling, grammar, and make any
    /// corrections needed" keeps contractions properly, but answers instead of
    /// correcting, rewrites "the thing is" into "The issue is", drops openers
    /// entirely, and leaks "Sure, here's the rewritten text:" into the output —
    /// which then gets pasted into the document. The mechanical framing here is
    /// what stops the model reading this as a chat request.
    ///
    /// The second paragraph is not decoration either — dropping it and keeping
    /// only the mechanics above was tried, and over 24 samples it deleted the
    /// whole second clause of "him and me was going to the shop but it dont open
    /// till ten", and turned "can you send me the file thanks" into "I can send
    /// you the file" — a request inverted into an offer. One is data loss and the
    /// other reverses the meaning; this wording did neither.
    ///
    /// The pattern behind all of it, stated carefully: it over-applies rules that
    /// tell it to transform, and ignores NARROW rules that tell it to hold back —
    /// but the broad "keep the wording" guard is load-bearing, which the
    /// contraction result on its own would have wrongly suggested it wasn't.
    static let defaultPolishInstructions = """
        Fix every spelling, grammar, capitalization and punctuation error. \
        Capitalize the first word of every sentence and the pronoun I. End every \
        sentence with the punctuation it needs. Split run-on sentences.

        Keep the original wording, tone and meaning — do not rephrase, shorten, \
        reorder or add anything.
        """
    /// The "those removals are the only ones" paragraph is doing specific work.
    /// Without it, three sentences here tell the model to remove things and the
    /// guard only forbade *adding* — so "remove filler" read as a general license
    /// to trim, and it cut words the speaker meant. "I'm not sure if anybody else
    /// can get this working well or not" came back without the "or not" every
    /// time; "worth it or not honestly" lost the "or not" and moved the
    /// "honestly".
    ///
    /// Adding "or leave anything out" to the guard alone barely helped — 1 case in
    /// 3. Closing the list is what fixed it: 3 in 3, on both, while still
    /// stripping the um and uh. The lesson matches the one on the set above: this
    /// model needs the *scope* of an instruction bounded, or it generalises it.
    static let defaultDictationInstructions = """
        Turn dictated speech into clean written text.

        Remove filler words and vocalized pauses — um, uh, er, like, you know, \
        I mean, sort of, and trailing "so yeah". Drop false starts, repeated \
        words, and self-corrections, keeping only what the speaker settled on \
        ("I went to the— I drove to the office" becomes "I drove to the office").

        Add capitalization and punctuation, and break run-on speech into \
        sentences and paragraphs where the sense changes. Fix obvious \
        misrecognized words only when the intended word is unmistakable from \
        context.

        Those removals are the only ones. Every other word the speaker said \
        stays, including words that add no new information.

        Keep the speaker's own words, voice and meaning. Do not summarize, \
        expand, reorder the ideas, make it more formal, add anything that \
        wasn't said, or leave anything out.
        """
    /// Storing text identical to the default would quietly pin it. Opening the
    /// Instructions window and clicking Save without typing anything is enough to
    /// do that, and from then on the saved copy wins and every later improvement
    /// to the default silently never arrives — which is exactly what happened
    /// when Auto-Correct kept dropping words after the wording was supposedly fixed.
    /// Nothing stored means "follow the default", so store nothing unless it
    /// genuinely differs.
    var polishInstructions: String {
        get { string(forKey: "polishInstructions") ?? UserDefaults.defaultPolishInstructions }
        set {
            if newValue == UserDefaults.defaultPolishInstructions {
                removeObject(forKey: "polishInstructions")
            } else {
                set(newValue, forKey: "polishInstructions")
            }
        }
    }
    var dictationInstructions: String {
        get { string(forKey: "dictationInstructions") ?? UserDefaults.defaultDictationInstructions }
        set {
            if newValue == UserDefaults.defaultDictationInstructions {
                removeObject(forKey: "dictationInstructions")
            } else {
                set(newValue, forKey: "dictationInstructions")
            }
        }
    }
    /// Correct Text: run dictated text through the model as soon as it lands. On by
    /// default — speech nearly always wants the filler stripped.
    var polishDictation: Bool {
        get { object(forKey: "polishDictation") as? Bool ?? true }
        set { set(newValue, forKey: "polishDictation") }
    }
    /// Dictation: which modifier is held to talk (Off = the tool is idle).
    /// Right ⌥ by default — nothing else claims it, so the tool works out of the
    /// box rather than sitting inert until someone finds the menu.
    var dictationHoldKey: HoldKey {
        get { HoldKey(rawValue: object(forKey: "dictationHoldKey") as? Int ?? HoldKey.rightOption.rawValue) ?? .rightOption }
        set { set(newValue.rawValue, forKey: "dictationHoldKey") }
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
/// Settings → Accessibility → Spoken Content). Liteswitch doesn't own this
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

    /// The combo integer is exactly Liteswitch's own Shortcut layout — Carbon
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
    // Push-to-talk dictation: monitors on the chosen modifier, and whether we
    // have dictation running right now.
    private var holdMonitors: [Any] = []
    private var dictating = false
    /// True from the moment dictation stops until Auto-Correct has finished with the
    /// text. `dictating` can't stand in for this: it clears the instant dictation
    /// stops, while the round trip that follows — select, copy, run the model,
    /// paste — keeps running for seconds afterwards. Dictating again inside that
    /// window lets the pending paste land in the middle of the new utterance,
    /// which is exactly how the text came back doubled and jumbled.
    private var correcting = false
    /// Insurance for the flag above. The model call has no timeout of its own, so
    /// without this one hung request would leave `correcting` set and the hold key
    /// dead until the app restarts. Long enough not to fire during a normal
    /// rewrite; short enough that a wedge recovers on its own.
    private var correctionWatchdog: DispatchWorkItem?
    /// Dictation lags speech, so the stop is deferred — this is the pending one,
    /// canceled if the key goes back down within the grace period.
    private var pendingDictationStop: DispatchWorkItem?
    /// Counts down the dead zone before dictation engages, so holding the key as
    /// an ordinary modifier doesn't start talking.
    private var dictationArmTimer: Timer?

    /// The field dictation is going into, and what it held before — enough to
    /// work out afterwards exactly what was inserted.
    private var dictationElement: AXUIElement?
    private var dictationBeforeText: String?
    /// When dictation started; only used if the field won't tell us its text.
    private var dictationStartedAt: Date?
    private var dictatedWordEstimate: Int {
        guard let start = dictationStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(start) * 2.5)   // ~150 wpm
    }
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
        // Before anything registers: hand over to the copy already running, if
        // there is one. Has to come first, since the damage a second instance
        // does is done by the very things below this line.
        if yieldToRunningInstance() { return }
        // A duplicate that quit needs somewhere to send the user, and this is it.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(showSettingsForDuplicateLaunch),
            name: Self.showSettingsNotification, object: nil)
        seedDefaultShortcutsIfNeeded()
        // The system broadcasts this when Appearance changes (including on the
        // automatic light/dark schedule). A view-level callback isn't dependable
        // here — this app has no Dock presence and its windows are usually not
        // frontmost — so listen for the broadcast instead.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(systemThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
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

    /// Sent by a duplicate on its way out, so the copy that's staying brings up
    /// settings — otherwise opening the app would look like nothing happened.
    private static let showSettingsNotification =
        NSNotification.Name("com.ethan.liteswitch.showSettings")

    @objc private func showSettingsForDuplicateLaunch() { showSettings() }

    /// Quit if another copy is already running, after pointing the user at it.
    /// Returns true when this instance is the one that should go away.
    ///
    /// Two copies do not share nicely. Each registers the same global hotkeys and
    /// installs its own dictation monitor, so one keypress fires twice and two
    /// Auto-Correct passes rewrite the same sentence while the other is pasting into
    /// it — which reads as dictated text coming back mangled and repeated.
    ///
    /// This asks which processes are running rather than setting
    /// LSMultipleInstancesProhibited, because LaunchServices keys that on the
    /// bundle it finds on disk. The way copies actually stacked up here was a
    /// rebuild replacing the bundle underneath a running instance: the new bundle
    /// looks like a different app to LaunchServices, so it would happily launch
    /// it — but the orphan still answers to this bundle id, so it is caught here.
    private func yieldToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        guard !others.isEmpty else { return false }

        // Launched together, each would see the other and both would quit. So the
        // one that started first stays, and an identical timestamp is settled by
        // the lower pid — any rule works as long as both sides reach the same one.
        //
        // The two fallbacks lean opposite ways on purpose, and both lean towards
        // yielding. A process launched by running the executable directly has no
        // launchDate at all, so dating ourselves `.distantPast` would make the
        // newcomer believe it was the incumbent and stay — which is exactly how
        // copies used to stack. Unknown self means "just started"; unknown other
        // means "already here".
        let launched = NSRunningApplication.current.launchDate ?? Date()
        let incumbent = others.first {
            let theirs = $0.launchDate ?? .distantPast
            return theirs == launched ? $0.processIdentifier < mine : theirs < launched
        }
        guard let incumbent else { return false }

        // A login launch that finds a copy running just goes quietly. A launch the
        // user asked for means they wanted the window, so the incumbent shows it.
        if !launchedAsLoginItem {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsNotification, object: nil, userInfo: nil,
                deliverImmediately: true)
            incumbent.activate()
        }
        // exit() rather than NSApp.terminate: nothing has been registered yet, so
        // there is nothing to unwind, and this cannot be delayed by the usual
        // should-terminate path. deliverImmediately above has already handed the
        // notification over.
        exit(0)
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

    /// Give a fresh install the default set. Runs once, and skips any tool that
    /// already has a shortcut, so it can never overwrite something you chose.
    private func seedDefaultShortcutsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didSeedShortcuts") else { return }
        d.set(true, forKey: "didSeedShortcuts")
        for panel in panels where Shortcut.load(panel) == nil {
            guard let code = defaultShortcuts[panel.defaultsKey] else { continue }
            Shortcut.save(Shortcut(keyCode: code, modifiers: UInt32(controlKey | optionKey | cmdKey)), panel)
        }
    }

    func setAppEnabled(_ on: Bool) {
        appEnabled = on
        defer { syncDictationMonitor() }
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
        syncDictationMonitor()

    }

    /// Redraw anything holding baked layer colors. The notification can arrive
    /// a beat before the new appearance resolves, hence the short delay.
    @objc private func systemThemeChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.settings?.appearanceChanged()
            self?.colorHistoryPanel?.appearanceChanged()
        }
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
            if usesHoldKey(panel) { continue }          // watched by a monitor, not a hotkey
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

        if panel.defaultsKey == "polish" {
            polishSelection()
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
                        self?.synthesizeSpotlight(then: panel.spotlightKey,
                                                  trigger: Shortcut.load(panel).map { CGKeyCode($0.keyCode) })
                    }
                }
                return
            }
        }

        synthesizeSpotlight(then: panel.spotlightKey,
                            trigger: Shortcut.load(panel).map { CGKeyCode($0.keyCode) })
    }

    // MARK: Correct Text

    /// Rewrite the selection in place: copy it, run it through the on-device
    /// model with the user's instructions, and paste the result back. The
    /// clipboard is borrowed for the round trip and put back afterwards.
    ///
    /// With nothing selected, it takes the whole field — ⌘A then copy — so the
    /// shortcut does something useful when you just want the thing you're looking
    /// at corrected. That fallback is deliberately NOT used for Auto-Correct: after
    /// dictation the selection is an estimate, and if it came back empty,
    /// selecting all would rewrite the entire document instead of the sentence
    /// you just spoke.
    func polishSelection(dictated: Bool = false, known: String? = nil) {
        // One round trip at a time. Two overlapping ones race over the clipboard
        // and the selection, and the loser's paste lands wherever the caret has
        // got to by then — the same failure as dictating again mid-rewrite, just
        // reached by pressing the shortcut twice. The dictated path claimed this
        // back in stopDictation; a manual press hasn't.
        if !dictated {
            if correcting { NSSound.beep(); return }
            beginCorrecting()
        }
        guard hasAccessibility else { endCorrecting(); promptForAccessibility(); return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        // Three ways to learn what's selected, cheapest first. Only the last one
        // touches the clipboard, and it's the only one that leaves a trace there.
        if let known {
            runPolish(known, dictated: dictated, restoring: saved)
            return
        }
        if let viaAX = selectedTextViaAX() {
            runPolish(viaAX, dictated: dictated, restoring: saved)
            return
        }

        copySelectionText { [weak self] text in
            guard let self else { return }
            if let text {
                self.runPolish(text, dictated: dictated, restoring: saved)   // ends it
            } else if dictated {
                self.endCorrecting()
                self.hud.hide()          // nothing to work on; leave the text alone
                Self.restoreClipboard(saved, on: pb)
            } else {
                // Nothing selected: take the lot.
                self.post(CGKeyCode(kVK_ANSI_A), .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    // Ask over AX again first. There was nothing to read a moment
                    // ago because nothing was selected; now there is. Skipping this
                    // is what still left a clipboard entry behind in apps that do
                    // answer — which is most of them, Electron included — whenever
                    // the shortcut was used without selecting anything first, the
                    // ordinary way to tidy something you just typed.
                    if let viaAX = self.selectedTextViaAX() {
                        self.runPolish(viaAX, dictated: dictated, restoring: saved)
                        return
                    }
                    self.copySelectionText { all in
                        guard let all else {
                            self.endCorrecting()
                            self.hud.showMessage("No text to correct", symbol: "text.badge.xmark", tint: .systemRed)
                            Self.restoreClipboard(saved, on: pb)
                            return
                        }
                        self.runPolish(all, dictated: dictated, restoring: saved)
                    }
                }
            }
        }
    }

    /// Copy whatever is selected and hand it back, or nil if nothing came.
    private func copySelectionText(then: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        post(CGKeyCode(kVK_ANSI_C), .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pb.changeCount != before, let text = Self.selectedText(from: pb),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { then(nil); return }
            then(text)
        }
    }

    /// What was actually selected, in characters.
    ///
    /// The plain-text flavor can't be trusted for this, because a rich editor
    /// flattens structure into it. Copy a checklist item in Notes and the plain
    /// flavor reads "- [ ] Buy milk" — but the checkbox is a paragraph attribute
    /// (an NSTextList), and the only characters selected are "Buy milk". Feed the
    /// flattened version to the model and paste the result back and the marker
    /// arrives as literal text in a paragraph that still draws its own checkbox,
    /// so the bullet appears twice: once drawn, once spelled out.
    ///
    /// The rich flavor is the honest one — its attributed string holds exactly the
    /// characters, with the list left as an attribute where it belongs. So prefer
    /// it whenever it's there, and take its absence as the signal that the source
    /// is a plain-text editor, where "- [ ]" really is content and has to survive
    /// untouched. That distinction is the whole point: the two cases need opposite
    /// handling, and which flavors the app offers is what tells them apart.
    private static func selectedText(from pb: NSPasteboard) -> String? {
        let plain = pb.string(forType: .string)
        for (type, doc) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd),
                            (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf)] {
            guard let data = pb.data(forType: type),
                  let attr = try? NSAttributedString(data: data, options: [.documentType: doc],
                                                     documentAttributes: nil),
                  !attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            var rich = attr.string
            // The rich flavor carries the paragraph's terminating newline where the
            // plain one doesn't; pasting that back would open a second list item.
            while rich.hasSuffix("\n") && plain?.hasSuffix("\n") != true { rich.removeLast() }
            return rich
        }
        return plain
    }

    /// Put back the whitespace the model trimmed off the ends.
    ///
    /// The model is asked to rewrite a sentence and returns exactly that, trimmed
    /// — which is right for the words and wrong for what surrounds them. The space
    /// on either side of a selection belongs to the document, not the sentence:
    /// when the line didn't already end in one, macOS dictation puts a space at
    /// the front of what it inserts, and the exact-selection diff quite correctly
    /// includes it. Trim that away on the way back and the new sentence lands
    /// flush against the previous one.
    private static func rewrap(_ rewritten: String, like original: String) -> String {
        // Can't happen — a blank selection is rejected before the model sees it —
        // but if it did, lead and trail would both be the whole string.
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rewritten
        }
        let lead = String(original.prefix { $0.isWhitespace })
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return lead + rewritten + trail
    }

    /// Put text on the clipboard without it turning up in clipboard history.
    ///
    /// Correct Text only uses the clipboard as a courier: the rewritten text goes on
    /// it so ⌘V can carry it into the app, and the original goes straight back
    /// after. Neither is something you copied, and both used to land in the very
    /// history the Clipboard panel shows — so one tidy left two stray entries.
    ///
    /// Which marker to use was measured against macOS 26's own history rather
    /// than assumed: it honors org.nspasteboard's TransientType, ConcealedType
    /// and AutoGeneratedType, and ignores com.apple.is-sensitive. Transient and
    /// AutoGenerated are the two that are actually true here. Concealed is not —
    /// it means "secret", and managers that honor it may expire or redact the
    /// entry, which would be a lie about what this is.
    private static func setClipboardQuietly(_ text: String, on pb: NSPasteboard) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in ["org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType"] {
            item.setString("", forType: NSPasteboard.PasteboardType(rawValue: marker))
        }
        pb.writeObjects([item])
    }

    /// Hand the clipboard back as it was found. Quietly, because putting it back
    /// isn't a fresh copy — recording it again would duplicate an entry that is
    /// already in the history from when it was really copied.
    private static func restoreClipboard(_ saved: String?, on pb: NSPasteboard) {
        guard let saved else { return }
        setClipboardQuietly(saved, on: pb)
    }

    /// Run the text through the model and paste the result over the selection.
    private func runPolish(_ text: String, dictated: Bool, restoring saved: String?) {
        let pb = NSPasteboard.general
        hud.showWaveform(tint: .systemPurple, mode: .processing)
        polish(text, dictated: dictated) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.endCorrecting()
                // Not the red warning triangle the other failures use. Those are
                // things you have to go and fix; this one is the model shrugging,
                // and your text is exactly where you left it.
                self.hud.showMessage("Unchanged", symbol: "questionmark.circle.fill",
                                     tint: .systemOrange)
                Self.restoreClipboard(saved, on: pb)
                return
            }
            Self.setClipboardQuietly(Self.rewrap(result, like: text), on: pb)
            self.post(CGKeyCode(kVK_ANSI_V), .maskCommand)   // paste over the selection
            // Auto-Correct names itself; the manual one doesn't need to. You pressed
            // the shortcut for that one, so what just happened isn't in question —
            // but Auto-Correct runs on its own, and if your words come back changed
            // it should be clear which thing changed them.
            self.hud.showMessage(dictated ? "Auto-Corrected" : "Corrected",
                                 symbol: "checkmark.circle.fill", tint: .systemGreen)
            // Give the paste a moment to land before handing the clipboard back —
            // and only release the hold key once it has, since that paste is the
            // thing a new dictation would otherwise land in the middle of.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Self.restoreClipboard(saved, on: pb)
                self.endCorrecting()
            }
        }
    }

    /// Whether the model talked *about* the text instead of rewriting it.
    ///
    /// Given something it can't make sense of, it doesn't fail — it explains:
    /// "I cannot rewrite this text because it appears to be a typo or corrupted
    /// input." That sentence was then pasted into the document in place of what
    /// was there, which is worse than doing nothing.
    ///
    /// Guessing at this from the text is unsatisfying, so the two principled
    /// routes were tried first and both lost.
    ///
    /// The framework does define `GenerationError.refusal` and
    /// `.guardrailViolation`, but they are for safety-policy blocks, not for
    /// this: over a run of deliberately unreadable inputs, zero errors were
    /// thrown and five refusals arrived as ordinary, successful content. As far
    /// as the API is concerned the model did its job.
    ///
    /// Guided generation does give a real typed flag — reachable on this
    /// toolchain via DynamicGenerationSchema, since the @Generable macro needs
    /// Xcode's plugin and build.sh uses plain swiftc. The flag is not worth
    /// having: it fired on one of six unreadable inputs and disagreed with itself
    /// across passes on the same input, "scasdassdfsadone" came back silently
    /// truncated to "sadone" with the flag clear, and forcing the schema lost the
    /// full stop off the end of most sentences — the very thing the instructions
    /// above exist to get right.
    ///
    /// Both signals are required, because either alone gets it wrong. Refusal
    /// phrasing catches real writing — "i cannot make it tomorrow sorry" tidies
    /// quite properly to "I cannot make it tomorrow. Sorry.", and so do "I am
    /// unable to attend the meeting" and "unfortunately the original message was
    /// lost". Low overlap catches real work too — "teh" becoming "the" keeps
    /// nothing, and stripping filler out of dictation keeps little. Together they
    /// separate cleanly: over the collected outputs, refusals kept none of the
    /// input's words while rewrites kept nearly all of them.
    private static func isRefusal(_ output: String, for input: String) -> Bool {
        let markers = ["cannot rewrite", "can't rewrite", "cannot assist", "can't assist",
                       "cannot process", "can't process", "cannot help", "can't help",
                       "unable to rewrite", "unable to process", "cannot determine",
                       "can't determine", "please provide", "different request",
                       "ready to assist", "does not contain", "no meaningful",
                       "random characters", "random sequence", "corrupted input"]
        let lower = output.lowercased()
        guard markers.contains(where: { lower.contains($0) }) else { return false }

        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        // A refusal sometimes quotes the text back at you — "I cannot rewrite the
        // text "xkcd flurb wozzle" as it does not contain meaningful content" —
        // and the quoted copy would otherwise read as the input having survived,
        // which let exactly that one through. Quoted material is the model citing,
        // not rewriting, so it doesn't count towards survival.
        func unquoted(_ s: String) -> String {
            var out = "", inside = false
            for c in s {
                if c == "\"" || c == "\u{201C}" || c == "\u{201D}" { inside.toggle(); continue }
                if !inside { out.append(c) }
            }
            return out
        }
        let before = words(input)
        guard !before.isEmpty else { return false }   // punctuation only; nothing to compare
        let after = words(unquoted(output))
        return Double(before.filter { after.contains($0) }.count) / Double(before.count) < 0.5
    }

    /// Run `text` through Apple Intelligence's on-device model with the saved
    /// instructions. Nothing leaves the Mac. `done` is called on the main queue,
    /// with nil if the model is unavailable or refuses.
    func polish(_ text: String, dictated: Bool = false, done: @escaping (String?) -> Void) {
        let instructions = dictated ? UserDefaults.standard.dictationInstructions
                                    : UserDefaults.standard.polishInstructions
        guard case .available = SystemLanguageModel.default.availability else {
            DispatchQueue.main.async { done(nil) }
            return
        }
        Task {
            var output: String?
            do {
                // Firm framing: without it the model tends to answer the text
                // rather than rewrite it.
                let session = LanguageModelSession(instructions: instructions +
                    "\n\nOutput only the rewritten text. Do not answer it, explain, or comment on it.")
                output = try await session.respond(to: "Rewrite this text:\n\n" + text).content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                output = nil
            }
            // A refusal is a valid-looking string, so it has to be caught here or
            // it gets pasted over the user's text as though it were the rewrite.
            // nil is the existing "couldn't do it" signal: the HUD says so and the
            // text is left alone.
            var result = output
            if let out = result, Self.isRefusal(out, for: text) { result = nil }
            let final = result
            await MainActor.run { done(final?.isEmpty == false ? final : nil) }
        }
    }

    // MARK: Push-to-talk dictation

    /// Watch the chosen modifier so dictation runs only while it's held. Carbon
    /// hotkeys never report a release, so this uses flagsChanged monitors — the
    /// global one covers other apps, the local one covers our own windows.
    func syncDictationMonitor() {
        for m in holdMonitors { NSEvent.removeMonitor(m) }
        holdMonitors = []
        if dictating { stopDictation() }

        let hold = UserDefaults.standard.dictationHoldKey
        guard appEnabled, hold != .off, let code = hold.keyCode, let flag = hold.flag else { return }

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == code else { return }
            // The flag is set while the key is down, clear once it's released.
            let down = event.modifierFlags.contains(flag)
            if down {
                // Pressing again while we're still finishing just carries on.
                if let pending = self.pendingDictationStop {
                    pending.cancel()
                    self.pendingDictationStop = nil
                    self.hud.showWaveform(tint: .systemGreen)
                    return
                }
                // Not while Auto-Correct still has the text: starting again here is
                // what let the previous rewrite paste itself into this sentence.
                if !self.dictating && !self.correcting { self.armDictation() }
            } else {
                self.disarmDictation()          // let go inside the dead zone: nothing happened
                if self.dictating { self.scheduleDictationStop() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handle) {
            holdMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { e in handle(e); return e }) {
            holdMonitors.append(l)
        }
        // A key pressed during the dead zone means the modifier was part of a
        // chord, so stand down rather than starting to dictate.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            self?.disarmDictation()
        }) { holdMonitors.append(g) }
    }

    /// Press the frontmost app's Edit ▸ Start/Stop Dictation item over the
    /// Accessibility API. The mic key itself can't be synthesized — macOS takes it
    /// at the HID layer, so it never becomes an event we can post — and by default
    /// dictation has no ordinary shortcut to send either. Driving the menu item
    /// leaves your own dictation setup exactly as it is.
    @discardableResult
    private func pressDictationMenuItem(starting: Bool) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return false }

        // Depth-first through the menu bar for the dictation item. Matching on a
        // "dictation" substring keeps it working when the wording shifts.
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 4 { return nil }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return nil }
            for child in children {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String)?.lowercased() ?? ""
                if title.contains("dictation") {
                    let wantsStop = title.contains("stop")
                    if wantsStop != starting { return child }
                }
                if let hit = search(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        guard let item = search(menuBar as! AXUIElement, depth: 0) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Wait out a short dead zone before engaging. The hold key is a real
    /// modifier — right ⌥ still types å and ø, and gets held for ⌥-click and
    /// ⌥-arrow — so dictation must not start the instant it goes down. Holding it
    /// alone past the buffer is unambiguous; any other key joining means it was a
    /// chord after all, and cancels.
    private func armDictation() {
        disarmDictation()
        dictationArmTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.dictationArmTimer = nil
            self?.startDictation()
        }
    }

    private func disarmDictation() {
        dictationArmTimer?.invalidate()
        dictationArmTimer = nil
    }

    private func startDictation() {
        // Distinguish the two failures: without Accessibility we can't read any
        // app's menus at all (a rebuild silently drops that trust), which looks
        // identical to an app that simply has no Dictation item.
        guard AXIsProcessTrusted() else {
            promptForAccessibility()   // macOS offers to open the pane
            hud.showMessage("Needs Accessibility", symbol: "exclamationmark.triangle.fill", tint: .systemRed)
            return
        }
        guard pressDictationMenuItem(starting: true) else {
            hud.showMessage("No Dictation menu here", symbol: "mic.slash.fill", tint: .systemRed)
            return
        }
        dictating = true
        dictationStartedAt = Date()
        captureDictationField()
        hud.showWaveform(tint: .systemGreen)
    }

    /// macOS keeps transcribing for a beat after you stop speaking, so stopping
    /// the instant the key comes up clips the last few words. Wait out that lag
    /// first — and if the key goes back down meanwhile, carry on as if it never
    /// let up. (Whether the trailing punctuation survives is macOS's business: it
    /// varies by app, and no amount of waiting here changes it.)
    private func scheduleDictationStop(after grace: TimeInterval = 1.5) {
        pendingDictationStop?.cancel()
        hud.showWaveform(tint: .systemOrange, mode: .processing)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDictationStop = nil
            self.stopDictation()
        }
        pendingDictationStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    /// Claim the text for the Auto-Correct round trip. Every path that finishes with
    /// it — including the ones that give up — has to call `endCorrecting`, or the
    /// hold key stays dead until the watchdog fires.
    private func beginCorrecting() {
        correcting = true
        correctionWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endCorrecting() }
        correctionWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// Safe to call when no tidy is in flight, so the shared paths can call it
    /// unconditionally rather than each having to know how they were reached.
    private func endCorrecting() {
        correcting = false
        correctionWatchdog?.cancel()
        correctionWatchdog = nil
    }

    private func stopDictation() {
        dictating = false
        pendingDictationStop?.cancel()
        pendingDictationStop = nil
        // Prefer the app's own Stop item; fall back to Escape, which ends
        // dictation while keeping whatever has already been transcribed.
        if !pressDictationMenuItem(starting: false) { post(CGKeyCode(kVK_Escape), []) }

        guard UserDefaults.standard.polishDictation else { hud.hide(); return }
        // Auto-Correct: select what was just dictated and rewrite it in place.
        // Dictation leaves the caret at the end of its insertion, so shift-select
        // back over it — that's the only handle we have on "the dictated text",
        // since it lands in the app, not in us.
        beginCorrecting()
        // Purple, not the amber above. The two waits look the same to the user but
        // aren't: amber is the grace period, where pressing again deliberately
        // carries straight on, and this one is the rewrite, where pressing again
        // used to drop the pending paste into the next sentence. Different states
        // that behave differently should not wear the same color.
        hud.showWaveform(tint: .systemPurple, mode: .processing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            // The exact diff hands back the text it selected; the estimate can't,
            // so that path still has to read the selection the slow way.
            let dictatedText = self.selectDictatedRunExactly()
            if dictatedText == nil { self.selectDictatedRun() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.polishSelection(dictated: true, known: dictatedText)
            }
        }
    }

    /// Note the focused field and its current text, so what dictation adds can be
    /// identified exactly rather than guessed at.
    private func captureDictationField() {
        dictationElement = nil
        dictationBeforeText = nil
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return }
        let field = element as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return }
        dictationElement = field
        dictationBeforeText = text
    }

    /// Select exactly what dictation inserted, by diffing the field against the
    /// snapshot taken when it started: the common head and tail are what was
    /// already there, so everything between them is new. Returns nil when the
    /// app won't expose its text (many Electron and web views), leaving the
    /// caller to fall back on the estimate.
    ///
    /// Hands back the text as well as selecting it. The diff has already worked
    /// out precisely which characters those are, so making the caller fetch them
    /// again with a ⌘C would be both redundant and visible: that copy is the
    /// app's own write to the clipboard, which lands in clipboard history where
    /// nothing this tool does belongs.
    private func selectDictatedRunExactly() -> String? {
        guard let field = dictationElement, let before = dictationBeforeText else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let after = value as? String, after != before else { return nil }

        // UTF-16 offsets, because that's what an AX range is counted in.
        let b = Array(before.utf16), a = Array(after.utf16)
        guard a.count > b.count else { return nil }
        var head = 0
        while head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let length = a.count - tail - head
        guard length > 0 else { return nil }

        var range = CFRange(location: head, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString,
                                           axRange) == .success
        else { return nil }
        return String(decoding: a[head..<(head + length)], as: UTF16.self)
    }

    /// Read the selection straight out of the focused field, no ⌘C involved.
    ///
    /// Worth trying before the clipboard for the same reason as above: a copy is
    /// the frontmost app's write, so it can't be marked transient from here and
    /// turns up in clipboard history. Plenty of apps won't answer — Notes exposes
    /// no focused element at all — hence the fallback rather than a replacement.
    private func selectedTextViaAX() -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Fallback when the field is opaque: walk back over roughly as many words as
    /// were spoken. An estimate, and it shows — it can take too little or too much.
    private func selectDictatedRun() {
        let words = min(max(dictatedWordEstimate, 1), 120)
        for _ in 0..<words { post(CGKeyCode(kVK_LeftArrow), [.maskShift, .maskAlternate]) }
    }

    /// Show the system color loupe (`NSColorSampler`), copy the picked color's
    /// code (the clipboard is text-only by design — see `copyColorCode`), and
    /// record it to Color History (which any open palette then refreshes). The
    /// sampler reads the screen out of process (no Screen Recording /
    /// Accessibility). A nil color (Esc) leaves everything untouched.
    ///
    /// `reopenHistory` is for picks started from the palette: it closes itself
    /// first (so it never floats while the loupe is up), and this brings it back
    /// once the pick finishes — including a canceled one.
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

    /// Capture Text: the system's own crosshair region selector
    /// (`/usr/sbin/screencapture -i`) writes a PNG, which Vision OCRs; the text
    /// lands on the clipboard with a confirmation pill. screencapture reads the
    /// screen in its own process, so Liteswitch needs no Screen Recording grant.
    /// A canceled selection (Esc) writes no file and is a silent no-op.
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
                else { return }   // canceled — nothing written
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
    /// if Liteswitch quits, so it can never orphan. No permission needed.
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

    /// Re-create the assertion with the current type if sleep is blocked — used
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
                                       "Liteswitch Keep Awake" as CFString, &id) == kIOReturnSuccess {
            keepAwakeAssertion = id
        }
    }

    /// A menu-bar cup that appears only while sleep is blocked (Liteswitch is
    /// otherwise menu-bar-less) — a persistent indicator, click it to turn off.
    private func updateKeepAwakeIndicator() {
        if keepAwakeAssertion != 0 {
            guard keepAwakeStatusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let img = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keep Awake")
            img?.isTemplate = true
            item.button?.image = img
            item.button?.toolTip = "Liteswitch Keep Awake is on — click to turn off"
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
    /// `trigger` is the key of the shortcut that fired, which has to be released
    /// before the sequence runs. Waiting only for the modifiers isn't enough: we
    /// park our own hotkeys while synthesizing, so a trigger key still held is no
    /// longer swallowed by us and its auto-repeat reaches whatever we just opened.
    /// With Clipboard on ⌃⌥⌘Return that meant Return landing in the panel —
    /// activating an entry and leaving it half-open.
    private func synthesizeSpotlight(then key: CGKeyCode, trigger: CGKeyCode? = nil,
                                     attempt: Int = 0) {
        guard hasAccessibility else {
            // Rather than silently doing nothing, ask — macOS shows the dialog
            // that leads straight to the setting.
            if attempt == 0 { promptForAccessibility() }
            return
        }
        var watch = [kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
                     kVK_Control, kVK_RightControl, kVK_Function].map { CGKeyCode($0) }
        if let trigger { watch.append(trigger) }
        let held = watch.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
        if held {
            // Waiting on the user's fingers: people hold a chord for a long
            // beat when they expect something to appear, so give them 2 s
            // (80 × 25 ms) before quietly giving up, not a fraction of one.
            guard attempt < 80 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.synthesizeSpotlight(then: key, trigger: trigger, attempt: attempt + 1)
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
            // Return and Delete can't be bound at all. Return means "activate"
            // inside every panel these shortcuts open, so a press that outlives
            // the chord lands in the panel and leaves it half-open; Delete is
            // already the gesture for clearing a binding here.
            if [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete]
                .contains(Int(event.keyCode)) {
                NSSound.beep()
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

/// A view that reports when the system flips between light and dark. Layer
/// colors (`.cgColor`) are resolved once when they're set, so anything drawn
/// into a layer has to be rebuilt on the flip or it keeps the old theme's
/// colors until the app restarts.
class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The settings window's content view. It knows where any open help sheets are,
/// so a click on the controls underneath can put them away — help is reference
/// material, not a mode you should have to remember to leave.
final class SettingsContentView: AppearanceAwareView {
    var sheetFrames: [NSRect] = []
    var onClickOutsideSheets: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !sheetFrames.isEmpty, !sheetFrames.contains(where: { $0.contains(p) }) {
            onClickOutsideSheets?()
        }
        super.mouseDown(with: event)
    }
}

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
    private let topMargin: CGFloat = 34
    private let titleTextH: CGFloat = 33
    private let titleSwitchGap: CGFloat = 10
    private let switchRowH: CGFloat = 28
    private let unitGap: CGFloat = 14
    private let descH: CGFloat = 20
    private let sectionGap: CGFloat = 18
    private let btnW: CGFloat = 100, btnH: CGFloat = 32
    private let bottomMargin: CGFloat = 20
    /// Gap between the groups and the button row; the (usually empty)
    /// conflict banner floats inside it rather than reserving its own band.
    private let footerGap: CGFloat = 22
    private var footerH: CGFloat { footerGap + btnH + bottomMargin }
    // Every card — Spotlight panel or System Tool — is the same width.
    private let boxW: CGFloat = 128
    private let boxGap: CGFloat = 12, innerPad: CGFloat = 11
    private let iconSize: CGFloat = 24
    private let headerBlockH: CGFloat = 46   // icon + title (no visible subtitle)
    private let itemH: CGFloat = 24, itemGap: CGFloat = 6
    // Grouping: Spotlight panels in one titled outline box, System Utilities in a
    // second one (same width) stacked below, its cards wrapping into rows.
    private let groupTitleH: CGFloat = 18, groupTitleGap: CGFloat = 6
    private let groupPad: CGFloat = 10
    private func groupWidth(_ w: CGFloat, _ count: Int) -> CGFloat {
        groupPad * 2 + w * CGFloat(count) + boxGap * CGFloat(count - 1)
    }
    private var group1W: CGFloat { groupWidth(boxW, spotlightPanels.count) }
    // The window is as wide as the Spotlight group; the other boxes match.
    private var winW: CGFloat { pad * 2 + group1W }
    private var contentW: CGFloat { winW - pad * 2 }
    private var spotlightPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { !isUtility($0.element) }.map { ($0.offset, $0.element) }
    }
    private var utilityPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { isUtility($0.element) && !isTextTool($0.element) }
            .map { ($0.offset, $0.element) }
    }
    private var textPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { isTextTool($0.element) }.map { ($0.offset, $0.element) }
    }
    /// Permission / Spoken Content state the current content was built for, so
    /// returning from System Settings rebuilds (and re-lights the strip) when any
    /// of them changed.
    /// The appearance the current content was built for, so a theme flip forces
    /// a rebuild (and nothing else does).
    private var builtAppearance: NSAppearance.Name?
    private var builtWithAX = true
    private var builtScreenRec = CGPreflightScreenCaptureAccess()
    private var builtSpoken = SpokenSelection.current
    /// Group keys whose help overlay is currently covering their box.
    private var helpShown: Set<String> = []
    private var instructionsWindow: InstructionsWindow?

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
        // Layer colors (.cgColor) resolve against NSAppearance.current, which
        // outside a draw cycle is the app default — not this window's appearance.
        // Building inside the window's own drawing appearance is what makes the
        // dark/light colors come out right, and what makes a rebuild after a
        // theme change actually change anything.
        effectiveAppearance.performAsCurrentDrawingAppearance { self.rebuildContent() }
    }

    private func rebuildContent() {
        RecorderButton.active?.cancelRecording()

        // ── Measure ────────────────────────────────────────────────────────
        // Spotlight cards are a header over a single shortcut field. The tool
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
        // System and text cards share a height, so the two boxes line up.
        let toolCardH = max(maxColumn(utilityPanels), maxColumn(textPanels)) + innerPad * 2
        let spotGroupBoxH = groupPad * 2 + spotCardH
        let utilGroupBoxH = groupPad * 2 + toolCardH
        let textGroupBoxH = groupPad * 2 + toolCardH
        let spotGroupH = groupTitleH + groupTitleGap + spotGroupBoxH
        let utilGroupH = groupTitleH + groupTitleGap + utilGroupBoxH
        let textGroupH = groupTitleH + groupTitleGap + textGroupBoxH
        let groupsH = spotGroupH + sectionGap + utilGroupH + sectionGap + textGroupH

        // Both permissions just light the bottom strip; neither blocks the
        // controls — macOS prompts for each on demand when a shortcut first
        // needs it (Accessibility for the synthesized panels, Screen Recording
        // the first time Capture Text runs).
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

        let v = SettingsContentView(frame: NSRect(x: 0, y: 0, width: winW, height: H))
        v.onClickOutsideSheets = { [weak self] in self?.dismissGroupHelp() }
        builtAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        v.onAppearanceChange = { [weak self] in
            guard let self,
                  self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != self.builtAppearance
            else { return }
            DispatchQueue.main.async { self.rebuild() }
        }

        let enabled = appDelegate?.appEnabled ?? true
        var yTop = H - topMargin

        yTop -= titleTextH
        let titleLabel = NSTextField(labelWithString: "Liteswitch")
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
            ? "Liteswitch is on: your shortcuts are live and it starts automatically at login. Switching off releases the shortcuts and stops it launching at login — unlike Quit, which only ends this session."
            : "Liteswitch is off: no shortcuts fire and it won't start at login. Switch on to restore both."
        capLabel.toolTip = switchTip
        sw.toolTip = switchTip
        capLabel.frame = NSRect(x: groupX, y: yTop + (switchRowH - capH) / 2, width: capW, height: capH)
        v.addSubview(capLabel)
        sw.frame = NSRect(x: groupX + capW + swGap, y: yTop + (switchRowH - swH) / 2, width: swW, height: swH)
        v.addSubview(sw)

        yTop -= unitGap + descH
        addPermissionPill(hasAX: hasAX, hasScreenRec: hasScreenRec, rowY: yTop, rowH: descH, in: v)

        let onChange: () -> Void = { [weak self] in
            self?.helpShown.removeAll()          // recording a shortcut closes help
            self?.appDelegate?.syncHotkeys()
            self?.rebuild()
        }
        let contentTop = H - hdrH

        // ── Three titled outlines, stacked: Spotlight, System, Text ──
        // Lay out one panel's card at the given left edge / top.
        func layoutCard(_ i: Int, _ panel: Panel, cardX: CGFloat, cardTop: CGFloat, cardH: CGFloat) {
            let bx = cardX
            let cardW = boxW
            let colW = cardW - innerPad * 2

            // The column card — fill only; the group outline carries the border.
            let card = NSView(frame: NSRect(x: bx, y: cardTop - cardH, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            // No fill of its own: the group's well is the one surface. Filled
            // cards inside a filled well is a box in a box, twelve times over.
            card.layer?.backgroundColor = NSColor.clear.cgColor
            card.alphaValue = enabled ? 1 : 0.5
            v.addSubview(card)

            let cx = bx + innerPad
            let top = cardTop - innerPad

            // Icon + title only; what each tool does is spelled out in the
            // group's help sheet, keeping each box clean.
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
            name.frame = NSRect(x: cx, y: top - iconSize - 20, width: colW, height: 17)
            v.addSubview(name)

            var lineTop = top - headerBlockH

            if usesHoldKey(panel) {
                // There's no shortcut to record — the tool is driven by holding a
                // modifier — so the key menu takes the field's place rather than
                // sitting under a readout that says the same thing.
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: HoldKey.menuOrder.map(\.label))
                popup.selectItem(at: HoldKey.menuOrder.firstIndex(of: UserDefaults.standard.dictationHoldKey) ?? 0)
                popup.isEnabled = enabled
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: 11)
                popup.target = self
                popup.action = #selector(dictationHoldChanged(_:))
                popup.frame = NSRect(x: cx, y: lineTop - itemH, width: colW, height: itemH)
                v.addSubview(popup)
            } else if mirrorsMacOSHotkey(panel) {
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

            // Tool option below the shortcut. Settings and Capture Text use a
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
                let btn = NSButton(title: "View…", target: self, action: #selector(viewColorHistoryTapped))
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
            if panel.defaultsKey == "polish" {
                let btn = NSButton(title: "Instructions…", target: self,
                                   action: #selector(editPolishInstructions))
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 11)
                btn.isEnabled = enabled
                btn.sizeToFit()
                let w = min(ceil(btn.frame.width), colW)
                btn.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(btn)
            }
            if panel.defaultsKey == "dictation" {
                centeredCheckbox("Auto-Correct", on: UserDefaults.standard.polishDictation,
                                 action: #selector(polishDictationChanged(_:)))
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

        // Each group is one centered row of cards, stacked with a gap between.
        func layoutRow(_ entries: [(index: Int, panel: Panel)], in box: NSRect, cardH: CGFloat) {
            let clusterW = CGFloat(entries.count) * boxW + CGFloat(entries.count - 1) * boxGap
            let startX = box.minX + (group1W - clusterW) / 2
            for (i, entry) in entries.enumerated() {
                layoutCard(entry.index, entry.panel,
                           cardX: startX + CGFloat(i) * (boxW + boxGap),
                           cardTop: box.maxY - groupPad, cardH: cardH)
            }
        }

        // System Utilities.
        let g2Top = contentTop - spotGroupH - sectionGap
        let g2Box = addGroup("System Utilities", x: pad, width: group1W,
                             top: g2Top, boxH: utilGroupBoxH, dimmed: !enabled, in: v)
        layoutRow(utilityPanels, in: g2Box, cardH: toolCardH)
        addGroupHelp(key: "utilities", title: "System Utilities", box: g2Box, titleTop: g2Top,
                     entries: utilityPanels, dimmed: !enabled, in: v)

        // Text Tools.
        let g3Top = g2Top - utilGroupH - sectionGap
        let g3Box = addGroup("Text Tools", x: pad, width: group1W,
                             top: g3Top, boxH: textGroupBoxH, dimmed: !enabled, in: v)
        layoutRow(textPanels, in: g3Box, cardH: toolCardH)
        addGroupHelp(key: "text", title: "Text Tools", box: g3Box, titleTop: g3Top,
                     entries: textPanels, dimmed: !enabled, in: v)

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
        quit.toolTip = "Quit Liteswitch for now. It still starts at login — use the switch above to stop that too."
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
        (v as? SettingsContentView)?.sheetFrames.append(box)

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
        }
        doc.frame = NSRect(x: 0, y: 0, width: innerW, height: y)
        doc.autoresizingMask = [.width]
        scroll.documentView = doc
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
    }

    /// Rebuild for a light/dark flip. Layer colors resolve once when set, so
    /// the whole content has to be rebuilt or it keeps the old theme's colors.
    func appearanceChanged() {
        builtAppearance = nil
        rebuild()
    }

    /// Put any open help sheets away. Called when the window loses focus or
    /// closes, and when anything outside a sheet is clicked — otherwise a sheet
    /// left open covers its controls again the next time the window appears.
    func dismissGroupHelp() {
        guard !helpShown.isEmpty else { return }
        helpShown.removeAll()
        rebuild()
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
        // An outline, not a fill. The container has to be here — without it the
        // labels float free of their rows and twelve cards read as one field —
        // but a filled well plus filled cards was a box in a box twelve times
        // over, and a well with unfilled cards was one gray too many. A hairline
        // does the binding without adding another surface.
        let boxFrame = NSRect(x: x, y: top - groupTitleH - groupTitleGap - boxH, width: width, height: boxH)
        let box = NSView(frame: boxFrame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        // Plain separatorColor: it's dynamic, so it tracks light/dark and matches
        // the help sheet's border. Putting withAlphaComponent on it resolves the
        // color against the default appearance instead — which came out brighter
        // in dark mode, not fainter.
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.alphaValue = dimmed ? 0.5 : 1
        v.addSubview(box)
        return boxFrame
    }

    /// A two-tone pill under the switch, in place of a description: the leading
    /// "System Permissions:" label on one gray, the permission lights on a
    /// second gray. Each light is a green dot when granted, or a red, underlined
    /// link when not — clicking fires the real macOS request (prompting the user
    /// and adding Liteswitch to that permission's list). Nothing here blocks the
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
                                : "Lets Files, Actions, Clipboard, and the Settings shortcut work. Click to ask macOS and add Liteswitch to the list.")
        let s = item("Screen Recording", granted: hasScreenRec, action: #selector(grantScreenRecording),
                     tip: hasScreenRec ? "Screen Recording is on — Capture Text can read the selected region."
                                       : "Lets Capture Text read the selected region. Click to ask macOS and add Liteswitch to the list (takes effect after a relaunch).")
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
    /// Liteswitch to that permission's list in System Settings.
    @objc private func grantAccessibility() { appDelegate?.promptForAccessibility() }
    @objc private func grantScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    @objc private func forceQuit() { NSApp.terminate(nil) }
    @objc private func saveAndClose() { close() }
    @objc private func smartToggleChanged(_ sender: NSButton) {
        dismissGroupHelp()
        UserDefaults.standard.settingsToggle = sender.state == .on
    }

    @objc private func dictationHoldChanged(_ sender: NSPopUpButton) {
        helpShown.removeAll()
        UserDefaults.standard.dictationHoldKey =
            HoldKey.menuOrder[safe: sender.indexOfSelectedItem] ?? .off
        appDelegate?.syncDictationMonitor()
        rebuild()   // the field above reports the new choice
    }

    @objc private func polishDictationChanged(_ sender: NSButton) {
        dismissGroupHelp()
        UserDefaults.standard.polishDictation = sender.state == .on
    }

    @objc private func editPolishInstructions() {
        if instructionsWindow == nil { instructionsWindow = InstructionsWindow() }
        instructionsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        instructionsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func colorFormatChanged(_ sender: NSPopUpButton) {
        dismissGroupHelp()
        UserDefaults.standard.colorFormat = ColorFormat(rawValue: sender.indexOfSelectedItem) ?? .hex
    }

    /// Open the palette — clearing lives in there, behind actually looking at
    /// what you'd be throwing away.
    @objc private func viewColorHistoryTapped() { appDelegate?.openColorHistory() }

    @objc private func removeBreaksChanged(_ sender: NSButton) {
        dismissGroupHelp()
        UserDefaults.standard.ocrKeepLineBreaks = sender.state != .on   // checked = remove breaks
    }

    @objc private func screenSleepChanged(_ sender: NSButton) {
        dismissGroupHelp()
        UserDefaults.standard.keepAwakeAllowDisplaySleep = sender.state == .on
        appDelegate?.reapplyKeepAwake()   // take effect now if sleep is blocked
    }

    @objc private func openSpokenContent() {
        let urls = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"]
        for s in urls where NSWorkspace.shared.open(URL(string: s)!) { break }
    }

    @objc private func appEnabledChanged(_ sender: NSSwitch) {
        dismissGroupHelp()
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
    func windowWillClose(_ notification: Notification) {
        RecorderButton.active?.cancelRecording()
        dismissGroupHelp()
    }
    func windowDidResignKey(_ notification: Notification) {
        RecorderButton.active?.cancelRecording()
        dismissGroupHelp()
    }

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

/// The editor for what Correct Text tells the on-device model. Two sets, because
/// the tool does two different jobs: correcting text you selected, and cleaning up
/// what you just dictated.
final class InstructionsWindow: NSWindow {
    private let selectionView = NSTextView()
    private let dictationView = NSTextView()

    init() {
        let w: CGFloat = 520, h: CGFloat = 520
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Correct Text Instructions"
        isReleasedWhenClosed = false

        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        /// One labeled box of instructions.
        func section(_ title: String, _ caption: String, _ tv: NSTextView,
                     text: String, y: CGFloat, boxH: CGFloat, resetAction: Selector) {
            let head = NSTextField(labelWithString: title)
            head.font = .systemFont(ofSize: 13, weight: .semibold)
            head.frame = NSRect(x: 20, y: y + boxH + 26, width: w - 160, height: 20)
            v.addSubview(head)

            let sub = NSTextField(labelWithString: caption)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.frame = NSRect(x: 20, y: y + boxH + 8, width: w - 160, height: 16)
            v.addSubview(sub)

            let reset = NSButton(title: "Restore Default", target: self, action: resetAction)
            reset.bezelStyle = .rounded
            reset.controlSize = .small
            reset.font = .systemFont(ofSize: 11)
            reset.sizeToFit()
            let rw = ceil(reset.frame.width) + 10
            reset.frame = NSRect(x: w - 20 - rw, y: y + boxH + 8, width: rw, height: 20)
            v.addSubview(reset)

            let scroll = NSScrollView(frame: NSRect(x: 20, y: y, width: w - 40, height: boxH))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            tv.string = text
            tv.font = .systemFont(ofSize: 12)
            tv.isRichText = false
            tv.isVerticallyResizable = true
            tv.autoresizingMask = [.width]
            tv.textContainer?.widthTracksTextView = true
            scroll.documentView = tv
            v.addSubview(scroll)
        }

        section("Typed Text Instructions", "Used when you run the shortcut on text you've selected.",
                selectionView, text: UserDefaults.standard.polishInstructions,
                y: 356, boxH: 74, resetAction: #selector(restoreSelection))
        section("Dictated Text Instructions", "Used by Auto-Correct, on what Dictate Text just typed.",
                dictationView, text: UserDefaults.standard.dictationInstructions,
                y: 80, boxH: 216, resetAction: #selector(restoreDictation))

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 110, y: 22, width: 90, height: 30)
        v.addSubview(save)

        let note = NSTextField(labelWithString:
            "Instructions for built-in AI — nothing leaves your computer.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.frame = NSRect(x: 20, y: 30, width: w - 140, height: 16)
        v.addSubview(note)

        contentView = v
    }

    @objc private func restoreSelection() { selectionView.string = UserDefaults.defaultPolishInstructions }
    @objc private func restoreDictation() { dictationView.string = UserDefaults.defaultDictationInstructions }

    @objc private func save() {
        func clean(_ s: String, fallback: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? fallback : t
        }
        UserDefaults.standard.polishInstructions =
            clean(selectionView.string, fallback: UserDefaults.defaultPolishInstructions)
        UserDefaults.standard.dictationInstructions =
            clean(dictationView.string, fallback: UserDefaults.defaultDictationInstructions)
        close()
    }
}

// MARK: - Waveform

/// The little bar meter the dictation pill shows. It's a motion cue, not a real
/// level meter — reading actual input would mean asking for the microphone, which
/// this app has no reason to hold — so the bars move on their own. Two motions:
/// a slow symmetric breathing while it listens, and a pulse travelling along the
/// row while it catches up, so the two states don't just differ by color.
final class WaveformView: NSView {
    enum Mode { case listening, processing }

    private var bars: [CALayer] = []
    private var heights: [CGFloat] = []      // eased toward the target each tick
    private var t: Double = 0
    private var timer: Timer?
    private let barW: CGFloat = 3, barGap: CGFloat = 3
    private let minH: CGFloat = 3

    var mode: Mode = .listening
    var tint: NSColor = .systemGreen {
        didSet { bars.forEach { $0.backgroundColor = tint.cgColor } }
    }

    init(barCount: Int = 7, height: CGFloat = 18) {
        let w = CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: height))
        wantsLayer = true
        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = tint.cgColor
            bar.cornerRadius = barW / 2
            bar.frame = NSRect(x: CGFloat(i) * (barW + barGap), y: (height - minH) / 2,
                               width: barW, height: minH)
            layer?.addSublayer(bar)
            bars.append(bar)
            heights.append(minH)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        t += 1.0 / 30
        let h = bounds.height, span = h - minH
        let n = bars.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the easing below does the smoothing
        for i in 0..<n {
            let target: CGFloat
            switch mode {
            case .listening:
                // A wave travelling along the row — each bar lags the one before
                // it, which is what makes it read as a waveform rather than bars
                // bouncing independently.
                let phase = t * 5.2 - Double(i) * 0.85
                let wave = abs(sin(phase))
                target = minH + span * CGFloat(0.12 + 0.88 * wave)
            case .processing:
                // A single pulse travelling along the row and wrapping round.
                let pos = (t * 4.2).truncatingRemainder(dividingBy: Double(n) + 1.5) - 0.75
                let d = Double(i) - pos
                target = minH + span * CGFloat(0.85 * exp(-d * d / 0.5))
            }
            heights[i] += (target - heights[i]) * 0.30   // ease toward it
            let barH = heights[i]
            bars[i].frame = NSRect(x: bars[i].frame.minX, y: (h - barH) / 2, width: barW, height: barH)
        }
        CATransaction.commit()
    }

    deinit { timer?.invalidate() }
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
    private weak var waveform: WaveformView?
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

    /// A pill that's just the animated bar meter — the dictation indicator.
    func showWaveform(tint: NSColor, mode: WaveformView.Mode = .listening) {
        let meter = WaveformView()
        meter.tint = tint
        meter.mode = mode
        let width = padH + meter.frame.width + padH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))
        meter.frame.origin = NSPoint(x: padH, y: (panelH - meter.frame.height) / 2)
        content.addSubview(meter)
        waveform?.stop()
        waveform = meter
        present(content, width: width, sticky: true)
        meter.start()
    }

    /// Take down a sticky pill.
    func hide() {
        waveform?.stop()
        hideTimer?.invalidate()
        dismiss()
    }

    /// SF Symbol + message (Capture Text confirmations), styled like the color pill.
    /// `sticky` leaves the pill up until `hide()` — for states that last as long
    /// as you hold a key, rather than momentary confirmations.
    func showMessage(_ message: String, symbol: String, tint: NSColor, sticky: Bool = false) {
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
        present(content, width: width, sticky: sticky)
    }

    /// Shared chrome: frost the pill, center it at the top, fade in, auto-hide.
    private func present(_ content: NSView, width: CGFloat, sticky: Bool = false) {
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
        guard !sticky else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        waveform?.stop()
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
    private var builtAppearance: NSAppearance.Name?

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

    /// Liteswitch is a menu-bar-less agent, so there's no File menu to supply
    /// ⌘W — wire it up here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Redraw for a light/dark flip — swatch borders and the pin badge are layer
    /// colors, which keep whichever theme they were created under.
    func appearanceChanged() {
        builtAppearance = nil
        reload()
    }

    /// Rebuild the content from the current store — called on open and after any
    /// pick / pin / clear / format change.
    func reload() {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.reloadContent() }
    }

    private func reloadContent() {
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

        let v = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: contentW, height: H))
        // Swatch borders and the pin badge are layer colors too, so a theme flip
        // has to redraw this the same way it redraws the settings window.
        builtAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        v.onAppearanceChange = { [weak self] in
            guard let self,
                  self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != self.builtAppearance
            else { return }
            DispatchQueue.main.async { self.reload() }
        }
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
