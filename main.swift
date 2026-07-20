// Lightswitch — flip any Spotlight panel on from anywhere.
//
// Lightswitch gives every Spotlight panel its own keyboard shortcut.
//
// macOS 26 gave Spotlight four panels — Apps ⌘1, Files ⌘2, Actions ⌘3,
// Clipboard ⌘4 — reachable only after opening Spotlight itself. Lightswitch lets
// you assign a global shortcut to each panel directly.
//
// How panels open:
//   • Apps      — launches the system stub /System/Applications/Apps.app
//                 (public API, no permissions, works even if ⌘Space is
//                 remapped). Falls back to synthesis if the stub is missing.
//   • Files / Actions / Clipboard — synthesizes ⌘Space then ⌘2/⌘3/⌘4, the
//                 documented gesture. Needs Accessibility to post keystrokes.
//
// Same construction as Key54 (github.com/grokcodile/key54): one file, no
// dependencies, compiled with swiftc. Runs as a background agent — launching
// it by hand opens Settings.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Panels

struct Panel {
    let name: String
    let subtitle: String
    let spotlightKey: CGKeyCode   // the ⌘N that selects it inside Spotlight
    let defaultsKey: String
}

let panels: [Panel] = [
    Panel(name: "Apps", subtitle: "App launcher", spotlightKey: CGKeyCode(kVK_ANSI_1), defaultsKey: "apps"),
    Panel(name: "Files", subtitle: "File search", spotlightKey: CGKeyCode(kVK_ANSI_2), defaultsKey: "files"),
    Panel(name: "Actions", subtitle: "Shortcuts & actions", spotlightKey: CGKeyCode(kVK_ANSI_3), defaultsKey: "actions"),
    Panel(name: "Clipboard", subtitle: "Clipboard history", spotlightKey: CGKeyCode(kVK_ANSI_4), defaultsKey: "clipboard"),
]

/// Virtual keycodes for F1–F20 — the one family allowed as modifier-less
/// hotkeys (they exist to be bare; a bare letter would hijack typing).
let fKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                              103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

/// A recorded shortcut: virtual keycode + Carbon modifier mask.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon mask (cmdKey | shiftKey | optionKey | controlKey)

    static func load(_ panel: Panel) -> Shortcut? {
        let d = UserDefaults.standard
        guard let code = d.object(forKey: panel.defaultsKey + "KeyCode") as? Int, code >= 0
        else { return nil }
        return Shortcut(keyCode: UInt32(code),
                        modifiers: UInt32(d.integer(forKey: panel.defaultsKey + "Modifiers")))
    }

    func save(_ panel: Panel) {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: panel.defaultsKey + "KeyCode")
        d.set(Int(modifiers), forKey: panel.defaultsKey + "Modifiers")
    }

    static func clear(_ panel: Panel) {
        let d = UserDefaults.standard
        d.removeObject(forKey: panel.defaultsKey + "KeyCode")
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
    private var hotKeys: [EventHotKeyRef?] = Array(repeating: nil, count: panels.count)
    private var hotKeyHandler: EventHandlerRef?
    private var settings: SettingsWindow?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installHandler()
        syncHotkeys()
        watchAccessibility()
        showSettings()   // hand-launched → show the window; login launch is silent-ish for v0.1 too
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
            let index = Int(id.id) - 1
            DispatchQueue.main.async { me.openPanel(index) }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    /// Reconcile registered hotkeys with saved shortcuts. A registered hotkey
    /// eats its combo system-wide, so only register what can actually work:
    /// Apps always can (it launches a stub app, no permissions); the synthesis
    /// panels only when Accessibility is granted. Nothing while recording.
    /// Registration failures (another app owns the combo) are collected for
    /// the settings banner rather than silently ignored.
    func syncHotkeys() {
        for (i, ref) in hotKeys.enumerated() where ref != nil {
            UnregisterEventHotKey(ref!)
            hotKeys[i] = nil
        }
        conflicted = []
        defer { settings?.refreshBanner() }
        guard !recording && !synthesizing else { return }
        for (i, panel) in panels.enumerated() {
            guard let sc = Shortcut.load(panel) else { continue }
            let isApps = panel.defaultsKey == "apps"
            guard isApps || hasAccessibility else { continue }
            let id = EventHotKeyID(signature: OSType(0x4B_4C_49_54) /* 'KLIT' */,
                                   id: UInt32(i + 1))
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, id,
                                             GetEventDispatcherTarget(), 0, &hotKeys[i])
            if status != noErr {   // e.g. eventHotKeyExistsErr: Raycast/Alfred owns it
                hotKeys[i] = nil
                conflicted.append("\(panel.name) (\(sc.label))")
            }
        }
    }

    // MARK: Opening panels

    func openPanel(_ index: Int) {
        guard panels.indices.contains(index) else { return }
        let panel = panels[index]
        if panel.defaultsKey == "apps" {
            let stub = URL(fileURLWithPath: "/System/Applications/Apps.app")
            if FileManager.default.fileExists(atPath: stub.path) {
                let config = NSWorkspace.OpenConfiguration()
                config.addsToRecentItems = false   // a hotkey fires many times a day
                NSWorkspace.shared.openApplication(at: stub, configuration: config) { [weak self] _, error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        self?.synthesizeSpotlight(then: panel.spotlightKey)
                    }
                }
                return
            }
            // No stub (shouldn't happen on 26+) — fall through to synthesis.
        }
        synthesizeSpotlight(then: panel.spotlightKey)
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

// MARK: - Shortcut recorder control

/// A button that records the next keystroke when clicked. Bare Esc cancels,
/// bare Delete clears the binding (with modifiers they record like any other
/// key). Only one recorder can capture at a time, and window close / focus
/// loss cancels it — otherwise the parked hotkeys would stay parked forever.
final class RecorderButton: NSButton {
    let panel: Panel
    private var monitor: Any?
    weak var appDelegate: AppDelegate?
    var onChange: (() -> Void)?

    /// The one recorder currently capturing, if any.
    private(set) static weak var active: RecorderButton?

    init(panel: Panel, appDelegate: AppDelegate?) {
        self.panel = panel
        self.appDelegate = appDelegate
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshTitle() {
        title = Shortcut.load(panel)?.label ?? "Record Shortcut"
    }

    @objc private func beginRecording() {
        RecorderButton.active?.cancelRecording()   // one recorder at a time
        guard monitor == nil else { return }
        RecorderButton.active = self
        appDelegate?.recording = true
        title = "Type shortcut…"
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

            // Bare Esc cancels; bare Delete clears. With real modifiers they
            // fall through and record normally (⌘⌫ is a legitimate chord).
            if bare && Int(event.keyCode) == kVK_Escape { return nil }
            if bare && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                Shortcut.clear(self.panel)
                return nil
            }
            // Chords need ⌘/⌥/⌃ so a bare letter can't hijack typing
            // system-wide — except F-keys, which exist to be pressed bare.
            guard !bare || fKeyCodes.contains(code) else {
                NSSound.beep()
                return nil
            }

            let sc = Shortcut(keyCode: code, modifiers: mods)
            // One chord, one panel: recording a combo another panel owns
            // steals it (System Settings behavior).
            for other in panels where other.defaultsKey != self.panel.defaultsKey {
                if Shortcut.load(other) == sc { Shortcut.clear(other) }
            }
            sc.save(self.panel)
            // Synthesis panels need Accessibility — ask the moment the user
            // records a binding that will require it.
            if self.panel.defaultsKey != "apps",
               let ad = self.appDelegate, !ad.hasAccessibility {
                ad.promptForAccessibility()
            }
            return nil   // swallow the keystroke
        }
    }

    /// Stop capturing without saving anything beyond what the monitor block
    /// already persisted. Safe to call redundantly.
    func cancelRecording() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        if RecorderButton.active === self { RecorderButton.active = nil }
        refreshTitle()
        appDelegate?.recording = false
        onChange?()
    }
}

// MARK: - Settings window

final class SettingsWindow: NSWindow, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var banner: NSTextField?
    private var recorders: [RecorderButton] = []
    private var loginNotice: String?

    init(delegate: AppDelegate) {
        appDelegate = delegate
        let w: CGFloat = 400, rowH: CGFloat = 46, pad: CGFloat = 20
        let headerH: CGFloat = 58, footerH: CGFloat = 74
        let h = headerH + rowH * CGFloat(panels.count) + footerH
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "Lightswitch"
        isReleasedWhenClosed = false
        center()

        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let header = NSTextField(labelWithString: "Give every Spotlight panel its own shortcut.")
        header.font = .systemFont(ofSize: 13, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: pad, y: h - 40, width: w - pad * 2, height: 20)
        v.addSubview(header)

        for (i, panel) in panels.enumerated() {
            let y = h - headerH - rowH * CGFloat(i + 1) + 8
            let name = NSTextField(labelWithString: panel.name)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.frame = NSRect(x: pad, y: y + 16, width: 150, height: 17)
            v.addSubview(name)

            let sub = NSTextField(labelWithString: panel.subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .tertiaryLabelColor
            sub.frame = NSRect(x: pad, y: y + 1, width: 150, height: 14)
            v.addSubview(sub)

            let rec = RecorderButton(panel: panel, appDelegate: appDelegate)
            rec.frame = NSRect(x: w - pad - 28 - 150, y: y + 6, width: 150, height: 26)
            rec.toolTip = "Click, then press a shortcut"
            rec.onChange = { [weak self] in self?.shortcutsChanged() }
            recorders.append(rec)
            v.addSubview(rec)

            let clear = NSButton(title: "✕", target: self, action: #selector(clearShortcut(_:)))
            clear.tag = i
            clear.isBordered = false
            clear.font = .systemFont(ofSize: 12, weight: .medium)
            clear.contentTintColor = .tertiaryLabelColor
            clear.toolTip = "Remove shortcut"
            clear.frame = NSRect(x: w - pad - 24, y: y + 8, width: 24, height: 22)
            v.addSubview(clear)
        }

        // Footer: banner (permission / conflicts / login note) + launch at login.
        let bannerField = NSTextField(wrappingLabelWithString: "")
        bannerField.font = .systemFont(ofSize: 11)
        bannerField.textColor = .systemOrange
        bannerField.frame = NSRect(x: pad, y: 36, width: w - pad * 2, height: 28)
        v.addSubview(bannerField)
        banner = bannerField

        let login = NSButton(checkboxWithTitle: "Launch at login",
                             target: self, action: #selector(toggleLogin(_:)))
        login.font = .systemFont(ofSize: 12)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.frame = NSRect(x: pad, y: 10, width: 160, height: 18)
        v.addSubview(login)

        contentView = v
        self.delegate = self
        refreshBanner()
    }

    private func shortcutsChanged() {
        // A recording may have stolen another row's chord — refresh them all.
        recorders.forEach { $0.refreshTitle() }
        appDelegate?.syncHotkeys()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        RecorderButton.active?.cancelRecording()   // ✕ during a recording aborts it too
        guard panels.indices.contains(sender.tag) else { return }
        Shortcut.clear(panels[sender.tag])
        shortcutsChanged()
    }

    /// One line of orange footer text; priority: missing permission, then
    /// hotkey conflicts, then the login-item approval note.
    func refreshBanner() {
        var text = ""
        if !(appDelegate?.hasAccessibility ?? false) {
            text = "Files, Actions, and Clipboard need Accessibility access "
                + "(System Settings → Privacy & Security) — Apps works without it."
        } else if let conflicts = appDelegate?.conflicted, !conflicts.isEmpty {
            text = "In use by another app: " + conflicts.joined(separator: ", ")
        } else if let notice = loginNotice {
            text = notice
        }
        banner?.stringValue = text
    }

    // Recording must never outlive the window's key status: a local NSEvent
    // monitor only sees events while we're the active app, so an orphaned
    // recording would park every hotkey with no way to resume them.
    func windowWillClose(_ notification: Notification) {
        RecorderButton.active?.cancelRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        RecorderButton.active?.cancelRecording()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Re-try conflicted registrations (the other app may have released
        // the combo) and reflect any outside changes.
        appDelegate?.syncHotkeys()
        recorders.forEach { $0.refreshTitle() }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        loginNotice = nil
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    loginNotice = "Approve Lightswitch in System Settings → General → Login Items."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        // Reflect reality, not the click — registration can fail or need
        // approval, and try? would leave the checkbox lying about it.
        let status = SMAppService.mainApp.status
        sender.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        refreshBanner()
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
