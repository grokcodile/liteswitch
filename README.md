# Keylight

*(working title)*

**Give every Spotlight panel its own keyboard shortcut.**

macOS 26 gave Spotlight four panels — **Apps** (⌘1), **Files** (⌘2),
**Actions** (⌘3), and **Clipboard** (⌘4) — but the only way to reach one is
to open Spotlight first and press its number. Keylight assigns each panel a
global shortcut of your own, so the clipboard history (or any other panel) is
one keystroke away from anywhere.

- **Apps** opens via the system's own `Apps.app` stub — instant, no
  permissions needed.
- **Files / Actions / Clipboard** open by synthesizing the documented
  Spotlight gesture (⌘Space, then the panel's number). This needs
  Accessibility access.

Built like its sibling [Key54](https://github.com/grokcodile/key54): a single
`main.swift`, no dependencies, no Dock icon, no menu bar item, no data
collection. Launch the app to open Settings and record your shortcuts.

## Build

```sh
bash build.sh    # → ./build/Keylight.app (ad-hoc signed)
```

Requires macOS 26+.

## Status

Early scaffold — functional, pre-release.

## License

MIT — © 2026 Ethan Darling ([@grokcodile](https://github.com/grokcodile))
