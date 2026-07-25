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
- **Color Picker**: a shortcut that pops the system color loupe, then copies the pixel under your cursor to the clipboard as the **code** — in Hex, RGB, HSL, or SwiftUI form (your choice) — plus the raw **color** for dropping into a color well. A pill flashes the swatch and code at the top of the screen. No Screen Recording permission needed.
- **Color History**: a shortcut that opens a floating palette of the colors you've picked — every pick (from the Color Picker too) lands here. Each swatch is labeled with its hex in an edit box you can click to give it a custom name. **Click** a swatch to re-copy its code (its full code is the swatch's tooltip), **drag** it out to drop the swatch as a PNG into Finder or any app that takes an image, and use the **pin** at its top-right to keep it — hollow on hover, solid once pinned, slashed when hovering a pinned one to show a click will remove it. Or hit the eyedropper **Pick** — the window steps out of the way while you sample, then comes back with the new color in it. It's an ordinary window, so you can leave it open beside your design tool until you close it. It keeps the last 20, and **pinned** colors persist at the top. This is how you reference past colors *visually* — the OS clipboard can't hold a swatch usefully, so LiteSwitch keeps its own.
- **Text Capture**: a shortcut that brings up the system's region selector; the text inside your selection is recognized on-device (Vision) and copied to the clipboard, with a pill showing how much was grabbed. Choose whether to **remove line breaks**. A native replacement for TextSniper. On macOS 26 the region selector needs **Screen Recording** permission — macOS prompts the first time you use it.
- **Keep Awake**: a toggle that stops your Mac from sleeping (an IOKit power assertion — the same thing `caffeinate` uses). While it's on, a coffee cup appears in the menu bar (click it to turn off); a **Screen Sleep** option lets the display still sleep while the system stays awake. A native replacement for Amphetamine / Caffeine. The assertion auto-releases if LiteSwitch quits, so it can't leave your Mac stuck awake.
- **Speak Text**: rather than re-implement speech, this surfaces macOS's own **Speak selection** (System Settings → Accessibility → Spoken Content) — the feature that reads your selected text aloud in the system voice you've chosen. The card shows the keyboard shortcut macOS has assigned to it (or **Not Set Up** if it's off), and a **Set Up… / Change…** button opens Spoken Content so you can enable it and pick the shortcut and voice. LiteSwitch reflects that state; macOS does the talking.
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
- **Accessibility** (System Settings → Privacy & Security → Accessibility) for the synthesized panels — Files, Actions, Clipboard, and the System Settings shortcut. **Apps and Color Picker work without it.**
- **Screen Recording** for **Text Capture** (macOS 26 gates the region selector behind it). No permission is needed for Keep Awake or Speak Text.

macOS prompts for each permission the first time a shortcut needs it — there's nothing to set up in advance. The settings window shows a status light for both at the bottom, and clicking a red one jumps straight to the right Settings pane.

## First run

1. Launch **LiteSwitch**. Its settings window opens.
2. Record a shortcut for each panel or tool you want (see [Shortcuts](#shortcuts)), then click **Done**. LiteSwitch keeps running in the background and starts automatically at login — silently, without showing the window.
3. The first time you fire a shortcut that needs Accessibility or Screen Recording, macOS asks for it. The status strip at the bottom of the window turns that permission's light green once it's granted.

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

**Color Picker** uses `NSColorSampler`, the system's own loupe. Because the screen sampling happens out of process, LiteSwitch itself never reads your screen — so it needs no Screen Recording permission. The pick lands on the clipboard as the **code text** in your chosen format, plus the raw **`NSColor`** (so it drops into a color well). It's text-only by design: an experiment to also copy a color *swatch image* — so you could spot the color in clipboard history — had to be dropped, because macOS's clipboard history snapshots any copied image into its own store and, on recall, re-offers it as that snapshot's file URL, which made recalling a color paste a file *path* instead of the code. Copying the code is the point, so text-only keeps paste reliable both live and from history.

**Text Capture** shells out to `/usr/sbin/screencapture -i` for the region selection, then runs Apple's on-device **Vision** OCR (`VNRecognizeTextRequest`) on the captured image — the recognition all happens locally, nothing leaves your Mac. On macOS 26 the interactive capture requires LiteSwitch to hold **Screen Recording** permission, which macOS prompts for the first time you use the shortcut.

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
