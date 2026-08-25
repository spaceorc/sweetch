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

- **Key remapping** — a Karabiner-shaped layer for keys macOS has no use for.
  A PC keyboard's context-menu key arrives as a plain keycode 110 that nothing is
  bound to; `menu = shift+ctrl+opt+0` in `remaps.txt` turns it into a hotkey you can
  bind anywhere. Rules are read from
  `~/Library/Application Support/sweetch/remaps.txt` (menu → **Edit Key Remaps…**)
  and reloaded whenever the status menu opens. **Detect Key…** in the menu reports
  the keycode of whatever you press next, so unlabelled keys are easy to find.

- **Screenshot capture + annotation** — two actions for `remaps.txt`: `@screenshot` fires
  the native region crosshair, `@screenshot-full` grabs the whole screen the pointer is on
  with no selection step. Either files the result in `~/Pictures/sweetch/` and opens it in
  a small editor. The defaults bind `f13` (where a PC keyboard's PrintScreen lands) and
  `⌃⌥⌘S` / `⌃⌥⌘F`, since Mac keyboards have no F13.

  Tools are `COPY | ARROW PENCIL CROP` across the top. **ARROW** draws arrows — click one
  to pick it up, drag its ends to reshape it, Delete to remove it. **PENCIL** draws freehand
  for underlining or circling something; a stroke can be picked up and moved the same way.
  **CROP** frames a region: drag
  one out, or just click for a default frame, then move it or drag any edge or corner;
  `APPLY`/`CANCEL` appear beside it (⏎ and esc). **COPY** (⏎ with no frame, or ⌘C) renders
  to the clipboard, closes the window and hands focus back where you were, so ⌘V lands in
  the right place. ⌘Z / ⇧⌘Z undo and redo; ⌘O opens any other image.

  Everything is **non-destructive** — the captured PNG is never modified. Arrows, the crop,
  the pending frame and the whole undo/redo history live in a sidecar under
  `~/Pictures/sweetch/.edits/`, so reopening a screenshot (menu → **Screenshots**) restores
  every shape, still draggable, and you can keep undoing where you left off. Drawing a
  frame and applying it are separate edits that undo separately. Only the clipboard ever
  receives flattened pixels.

  While an editor window is open sweetch becomes a regular app — Dock icon, ⌘-Tab, a Window
  menu — and slips back into the menu bar when the last one closes.

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
| Key remaps and actions | `~/Library/Application Support/sweetch/remaps.txt` (no rebuild) |
| Screenshot library | `~/Pictures/sweetch/` (edits in `.edits/`) |

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
- The remap layer runs **before** the hotkey bindings and sees key *up* events too —
  swallowing only the down half would leave apps with a release for a press they never
  got. Its synthetic output carries the same marker as every other event we post, so it
  passes straight back through the tap (a remap therefore can't trigger sweetch's own
  hotkeys — remap to something else and bind that).
- The screenshot editor stores **documents, not pixels**: an `EditDoc` of arrows and a crop
  rect in original-image coordinates, with snapshot-based undo/redo persisted alongside it.
  Snapshots rather than commands because the document is a handful of structs — copying it
  costs nothing, and "reopen tomorrow and keep pressing undo" then falls out for free.
  A crop narrows what's *displayed* rather than trimming anything, which is why undoing one
  brings the pixels back and why arrows drawn while cropped don't move when it's removed.
- Capture shells out to `/usr/sbin/screencapture -i` rather than reimplementing a selection
  overlay: it's the same crosshair the system uses, and the process exiting is a reliable
  "done or cancelled" signal. Note it exits 0 even on cancel, so the caller also checks that
  a file actually appeared.
- Synthesized events are tagged with a marker in `eventSourceUserData`
  (ASCII `"sweetch\0"`) so the tap can recognise and pass through its own
  events without re-processing them.
