# Hone

A **modular macOS power-tools suite** that lives in the menu bar. One refined app
to replace a pile of single-purpose utilities — each tool is a self-contained
*module* you flip on or off, and new tools slot in without touching the rest.

> Status: early but functional. **Scroll** (replaces [MOS](https://github.com/Caldis/Mos))
> and **Window Peek** (replaces [DockDoor](https://github.com/ejbills/DockDoor)) both
> work as v1.

## Tools

| Tool | Replaces | Status | What it does |
|------|----------|--------|--------------|
| **Scroll** | MOS | ✅ Working | Reverses the physical mouse wheel independently of the trackpad, and turns discrete wheel notches into smooth, eased pixel scrolling. |
| **Window Peek** | DockDoor | ✅ Working (v1) | Hover a Dock icon to preview that app's open windows as live thumbnails, then click one to focus it. |

## Requirements

- macOS 14+
- Xcode / Swift toolchain (build only) — `swift --version` should report 6.x

## Build & run

```bash
./setup-signing.sh   # once: create the stable self-signed cert (dedicated keychain)
./build.sh           # compile + sign (stable) + install to /Applications + relaunch
./build.sh debug     # faster debug build
```

`Hone` appears in the menu bar (no Dock icon). Both tools need **Accessibility**
access — toggle one on and macOS will prompt; grant it in System Settings ▸
Privacy & Security ▸ Accessibility. **Window Peek** additionally uses **Screen
Recording** for live window thumbnails (it still works without it, showing titles only).

### Why the stable signature matters

macOS ties Accessibility/Screen-Recording grants to the app's **code signature**.
Ad-hoc signing (`codesign --sign -`) produces a *different* signature every build,
so the grant is silently lost on each rebuild and the app keeps re-prompting.
`setup-signing.sh` creates a persistent self-signed certificate in a dedicated
keychain; `build.sh` signs with it, giving a stable Designated Requirement
(`identifier "com.tiagof.hone" and certificate leaf = H"…"`) — so you grant
permission **once** and it sticks across rebuilds. (Same approach as Clippy/Sleepy.)

## Architecture

Everything is a `HoneModule` — a protocol carrying the tool's metadata, its
`start()`/`stop()` lifecycle, and its SwiftUI settings pane. `ModuleManager`
registers the modules, restores their saved on/off state at launch, and keeps
them in sync with the Accessibility permission.

```
Sources/Hone/
├── App/            HoneApp (@main, MenuBarExtra + Settings) · AppDelegate
├── Core/           HoneModule protocol · ModuleManager · Permissions · LaunchAtLogin
├── UI/             MenuBarContent · SettingsView
└── Modules/
    ├── Scroll/     ScrollModule · ScrollEventTap · ScrollAnimator · ScrollSettings(+View)
    └── WindowPeek/ WindowPeekModule · WindowPeekController · DockObserver ·
                    WindowEnumerator · WindowFocuser · WindowPeekPanel(+View) · AXHelpers
```

### How the Scroll tool works

A session-level `CGEventTap` inspects every scroll event:

- **Continuous** input (trackpad, Magic Mouse) is passed through untouched — the
  system's natural-scrolling behaviour is respected.
- **Discrete** mouse-wheel input is optionally direction-flipped, then (if smooth
  scrolling is on) swallowed and replaced by a stream of small pixel-scroll events
  that ease out over ~120 Hz frames via `ScrollAnimator`.

Synthetic events are marked continuous, so the tap ignores its own output (no loop).

### How the Window Peek tool works

`DockObserver` hit-tests the cursor against the system-wide AX tree each move
(throttled) to detect when it's over an application Dock icon. On hover,
`WindowEnumerator` lists that app's normal windows via `CGWindowList` (titles
enriched from the AX API so they show without Screen Recording) and captures a
thumbnail per window. `WindowPeekPanel` — a borderless, non-activating floating
panel — shows them above the icon; clicking one calls `WindowFocuser`, which
activates the app and raises the matching AX window. Hover-intent keeps the panel
alive while you move from the icon to the panel.

## Adding a new tool

1. Create `Sources/Hone/Modules/<Name>/<Name>Module.swift` conforming to
   `HoneModule` (see `ScrollModule` for the full shape).
2. Add one line to `ModuleManager.registerModules()`.

That's it — the menu row, the settings sidebar entry, persistence, and the
permission flow are all wired off the protocol.

## Roadmap

- **Window Peek** polish: migrate thumbnails to ScreenCaptureKit (drop the
  deprecated capture API), support left/right Dock positions, keyboard navigation
  and click-to-close-window.
- Per-app scroll overrides (exclusion list) for the Scroll tool.
- App icon + stable signing (so Accessibility grants survive rebuilds) + Sparkle updates.
- Future modules: keyboard remaps, window snapping, clipboard history…
