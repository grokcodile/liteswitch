<img src="docs/icon.png" alt="LiteSwitch Icon" width="96"/>

# LiteSwitch

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

**LiteSwitch** is a tiny macOS utility that flips any Spotlight panel on from anywhere. macOS 26 gave Spotlight four panels — **Apps** (⌘1), **Files** (⌘2), **Actions** (⌘3), and **Clipboard** (⌘4) — but reaching one means opening Spotlight first, then pressing its number. That's walking to the lamp and turning the dial. LiteSwitch wires each panel (and System Settings, as a bonus utility) to its own global shortcut, so the panel you want flips on with one chord.

It runs as a background agent — no Dock icon, no menu bar item — and starts at login. Launching it by hand opens its settings window.

## Features

- A global shortcut for every Spotlight panel — Apps, Files, Actions, Clipboard — plus one for System Settings.
- One global shortcut per panel; recording a combo another panel owns moves it over automatically.
- **Apps** opens through the system's own `Apps.app` stub — instant, no permissions needed (with a synthesized fallback if the stub is ever missing).
- **Files / Actions / Clipboard** open by synthesizing the documented Spotlight gesture (⌘Space, then the panel's number).
- **Smart Toggle** for System Settings: press the shortcut a second time and you're returned to the app you came from.
- **Color Picker**: a shortcut that pops the system color loupe, then copies the pixel under your cursor — in Hex, RGB, HSL, or SwiftUI form (your choice) — and flashes a pill with the swatch and code at the top of the screen. No Screen Recording permission needed.
- **Text Capture**: a shortcut that brings up the system's region selector; the text inside your selection is recognized on-device (Vision) and copied to the clipboard, with a pill previewing what was grabbed. Choose whether to **preserve or remove line breaks**. A native replacement for TextSniper — and, like Color Picker, no Screen Recording permission needed.
- Shortcut conflicts with other apps are detected and surfaced in the settings window rather than failing silently.
- Runs silently in the background and starts at login; opening the app again brings up settings.

## Install

### Build from source

```sh
bash build.sh    # → ./build/LiteSwitch.app (ad-hoc signed)
```

Copy `build/LiteSwitch.app` into `Applications` and launch it. An ad-hoc build isn't notarized, so its first launch shows the "unidentified developer" warning — clear it once by right-clicking **LiteSwitch → Open**.

The app icon ships pre-generated (`icon/AppIcon.icns`); regenerate it from the vector source with `icon/make-icns.sh` (needs `brew install librsvg`).

## Requirements

- macOS 26 or later (the four-panel Spotlight).
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) for the synthesized panels — Files, Actions, Clipboard, and the System Settings shortcuts. **Apps, Color Picker, and Text Capture work without it** (and none of them need Screen Recording either).

## First run

1. Launch **LiteSwitch**. Its settings window opens.
2. Grant **Accessibility** permission — the window walks you through it and updates the moment permission lands.
3. Record a shortcut for each panel or tool you want (see [Shortcuts](#shortcuts)), then click **Done**. LiteSwitch keeps running in the background and starts automatically at login — silently, without showing the window.

## Shortcuts

A fresh install ships with **no shortcuts** — you assign the ones you want. Each
panel and tool has a single field: click it to record a shortcut, or press
**Delete** while recording to clear it. A natural set is ⌘1–⌘4 for the panels
(the same numbers Spotlight uses, now working from anywhere), but nothing stops
you from picking your own.

**System Tools** — Settings, Color Picker, and Text Capture — sit in their own group, each with its own option: a **copy-format** select menu for Color
Picker (Hex by default — also RGB, HSL, SwiftUI), a **Smart Toggle** checkbox for
Settings (on by default), and a **Remove Breaks** checkbox for Text Capture (off
by default — check it to strip the OCR's line breaks onto one line).

## How it works

Shortcuts are registered as Carbon global hotkeys (`RegisterEventHotKey`) — no event tap, so LiteSwitch never sits in your keyboard's event path. **Apps** launches the system stub at `/System/Applications/Apps.app` via `NSWorkspace` (public API). The other panels post the documented Spotlight gesture — ⌘Space, a ~30 ms beat, then the panel's ⌘-number — first waiting for you to release any lingering modifiers so the synthesized chord lands clean. While the sequence is in flight LiteSwitch's own hotkeys are parked, which is what lets ⌘1–⌘4 themselves serve as the global shortcuts without re-triggering.

**Color Picker** uses `NSColorSampler`, the system's own loupe. Because the screen sampling happens out of process, LiteSwitch itself never reads your screen — so it needs no Screen Recording permission — and the picked color is copied both as text (in your chosen format) and as an `NSColor`, so it drops straight into a color well too.

**Text Capture** shells out to `/usr/sbin/screencapture -i` for the region selection, then runs Apple's on-device **Vision** OCR (`VNRecognizeTextRequest`) on the captured image. Same principle as the color loupe: the system tool reads the screen in its own process, so LiteSwitch needs no Screen Recording permission — the recognition all happens locally.

## Uninstall

1. Open LiteSwitch, toggle the switch to **Disabled** (this removes the login item), then click **Quit**. (Or just `killall LiteSwitch`.)
2. Delete **LiteSwitch.app** from `Applications`.
3. Optionally remove its entry under System Settings → Privacy & Security → Accessibility.

## The name

You flip a light switch without looking at it — that's the bar: the panel you want, on, in one motion, from anywhere. And it's *lite*: one Swift file, no dependencies, no Dock icon, no menu bar item, no data collection.

## Notes

LiteSwitch synthesizes keystrokes to drive Spotlight, which is incompatible with the Mac App Store sandbox — it's built from source for now.

## License

Released under the [MIT License](LICENSE).

## Author

Built by **Ethan Darling** — [@grokcodile](https://github.com/grokcodile) on GitHub · [u/grokcodile](https://www.reddit.com/user/grokcodile) on Reddit · [LinkedIn](https://www.linkedin.com/in/ethandarling/).
