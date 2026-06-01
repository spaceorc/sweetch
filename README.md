# sweetch

A tiny macOS keyboard-layout switcher in the spirit of Punto Switcher.
Runs as a menubar utility with no Dock icon.

## Features

- **Cmd+Space** — instant toggle between the two configured layouts
  (default: ABC ↔ Russian PC) via the Text Input Sources API.
  Bypasses the system layout switcher's animation entirely.
- **Option+Space** — context-aware "convert":
  - **With selection:** reads the selected text via Accessibility, deletes it
    with Backspace, switches layout, and re-types the converted string
    character-by-character. Works in native Cocoa apps (Notes, TextEdit, Mail,
    Safari, Xcode, …) and Electron apps (Slack, Discord, VS Code, …).
  - **No selection:** converts the last typed word using a ring buffer of
    recent keystrokes — backspaces it, switches layout, replays the keyCodes.
    A second press toggles back.

## Requirements

- macOS 13+
- Xcode 15+ / Swift 5.10+
- Two installed input sources whose IDs match `primaryIDs` and `secondaryIDs`
  in `Sources/sweetch/InputSourceSwitcher.swift` (default: `com.apple.keylayout.ABC`
  or `com.apple.keylayout.US`, and `com.apple.keylayout.RussianWin`).

## Build & install

```sh
make app          # builds Sources/ into build/sweetch.app and ad-hoc-codesigns
make run          # the same, plus opens the bundle
```

The first run will:

1. Prompt for **Accessibility** (System Settings → Privacy & Security →
   Accessibility). The tap that intercepts hotkeys and synthesizes replays
   requires this.
2. Create a self-signed code-signing identity called `sweetch-dev` in your
   login keychain (`make setup-signing` runs implicitly via `make app`). This
   gives the bundle a stable *designated requirement*, so the Accessibility
   grant survives rebuilds — without it every rebuild looks like a different
   app to TCC and the permission resets.

If you ever switch identity or the TCC entry gets confused, `make tcc-reset`
clears the Accessibility entry for `com.spaceorc.sweetch`.

## Configuration

Hotkeys and layout choices are currently constants in source — edit and rebuild:

| What | Where |
|---|---|
| Toggle hotkey | `AppDelegate.swift` — `switchHotkey` |
| Convert hotkey | `AppDelegate.swift` — `convertHotkey` |
| Layout IDs | `InputSourceSwitcher.swift` — `primaryIDs`, `secondaryIDs` |
| Buffer invalidation rules | `AppDelegate.handleKeyDown` |

To discover input source IDs installed on your machine, watch the log on
startup — sweetch dumps every keyboard source it sees:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.spaceorc.sweetch"' --level info
```

## Limitations

- **Terminal-like apps** (iTerm2, Terminal.app) don't expose an editable
  selection through Accessibility, so selection-convert falls back to
  last-word convert there. The displayed text in a terminal isn't a text
  field; there's no way to programmatically replace it short of pasting.
- **Single Backspace deletes the whole selection** assumption: holds in every
  text widget I've tested. If you find one where it doesn't, the selection
  read still works — just the write needs more Backspaces.
- **Distribution outside this machine** would need a real Developer ID and
  notarization — the ad-hoc / self-signed bundle here is for personal use.

## Design notes

A few non-obvious decisions worth knowing if you go reading the code:

- The selection-convert path uses **AX read + synthesized typing**, not AX
  write. `AXUIElementSetAttributeValue(kAXSelectedTextAttribute, …)` returns
  `.success` in Electron apps but silently no-ops the contenteditable
  underneath — Electron's AX layer is a read-only mirror. Typing each char
  via `CGEvent` is the lowest common denominator that actually works.
- Convert is **dispatched off the event-tap thread** because
  `CGEventSource.flagsState` lies while the tap callback is blocked — the
  hotkey-release wait can only see clean modifier state once the callback
  has returned.
- Synthesized events are tagged with a marker in `eventSourceUserData`
  (ASCII `"sweetch\0"`) so the tap can recognise and pass through its own
  events without re-processing them.
