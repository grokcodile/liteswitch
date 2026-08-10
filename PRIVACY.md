# Privacy Policy

**Effective August 5, 2026**

> **The short version:** Pullcord collects no data. There are no accounts, no
> analytics, and no tracking — in the app or on the website. Everything you
> configure, and everything it processes, stays on your Mac.

## The app

- Pullcord has no account system and no telemetry. It never collects, stores,
  or transmits personal information.
- There is no license check, no crash reporting, and no "anonymous usage
  statistics".
- The app's only network activity is checking GitHub's public API for a newer
  release, and downloading one if you choose to update. These are ordinary web
  requests with no personal identifiers added; GitHub's standard server logging
  applies. Opening Help, the source repository or the tip jar from the About
  popover hands the link to your browser.
- Your settings — shortcuts, rewrite actions, color history, the list of apps
  that pause Pullcord — are stored locally in macOS's own preferences and
  never leave your Mac.

### What the permissions are for

- **Accessibility** is used to synthesize keystrokes (opening Spotlight's
  panels, driving dictation) and to read and replace the text you have selected
  when you use Rewrite Text or dictation Auto-Correct. That text is read only at
  the moment you invoke the tool, is used only to produce the replacement, and
  is never stored or transmitted.
- **Screen Recording** is used by Capture Text alone. macOS requires it for the
  region selector. The captured image is OCR'd on your Mac and the temporary
  file is discarded.

### The features that involve your content

All three run on-device, and none of them send anything anywhere:

- **Rewrite Text** uses Apple Intelligence's on-device model
  (`FoundationModels`). Your text is processed on your Mac. No API key, no
  server, no per-token cost — because nothing is sent.
- **Capture Text** uses Apple's Vision framework for OCR, on your Mac.
- **Dictate Text** adds a push-to-talk key on top of **macOS's own dictation**.
  The transcription is performed by macOS, not by Pullcord, and is governed by
  [Apple's privacy policy](https://www.apple.com/legal/privacy/) and your own
  dictation settings in System Settings.

Several tools put their result on the clipboard — a color code, captured text,
a rewrite. That is the clipboard on your Mac, and macOS's own clipboard history
rules apply to it.

## The website

- The site is static: no cookies, no analytics, no trackers, no embedded
  third-party scripts or fonts.
- It is hosted on GitHub Pages, which — like any web host — may keep standard
  server logs (such as IP addresses) per
  [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Third-party services

If you choose to use them, these services have their own privacy policies:

- **GitHub** — hosts the code, the releases, and the site.
- **Homebrew** — if you install or update via `brew`.
- **Ko-fi** — if you leave a tip. Pullcord never sees any payment details.

## Changes

If this policy ever changes, the update will be posted here with a new
effective date. Given what Pullcord is — a small, open-source utility that
does its work on your Mac — don't expect much to change.

## Contact

Questions? Email [pullcord@ethans.email](mailto:pullcord@ethans.email) or
[open an issue](https://github.com/grokcodile/pullcord/issues).
