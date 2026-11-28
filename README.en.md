<div align="center">
  <img src="Resources/AppIcon.png" alt="Vorsmate" width="96" />
  <h1>Vorsmate</h1>
  <p>A native Mac menu bar panel for input sources, audio devices, fan control, time comparison, and system utilities.</p>
  <p>
    <a href="README.md">简体中文</a> ·
    <strong>English</strong> ·
    <a href="https://github.com/0xTotoroX/vorsmate/releases/latest">Download</a> ·
    <a href="https://github.com/0xTotoroX/vorsmate/issues">Issues</a>
  </p>
  <p>
    <a href="https://github.com/0xTotoroX/vorsmate/actions/workflows/ci.yml"><img src="https://github.com/0xTotoroX/vorsmate/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  </p>
</div>

## Features

Switch between Information, Tools, and System by clicking a tab, scrolling a mouse wheel horizontally, or swiping sideways with two fingers on a trackpad. Toggle and reorder modules under `功能模块…` in the top-right menu. Tasks stays at the bottom of Information. Built with SwiftUI and AppKit, Vorsmate supports system Liquid Glass on macOS 26+. Optional weather and market modules fetch their own data and require no account.

### Built-in modules

| Category | Module | What it does |
| --- | --- | --- |
| System | Input sources | Switch or lock system input sources quickly, or drag rows to set automatic selection priorities. |
| System | Audio devices | Manage microphone and playback device priorities and locks independently, with automatic fallback on disconnect and restore on reconnect; supported wireless receivers qualify only when a transmitter connects. |
| System | Fan control | Switch across Automatic, Balanced, Enhanced, and Custom profiles with smoothed temperature curves, fixed speeds, and automatic restore on startup and wake. |
| Information | Time comparison | View local and US Pacific time side by side, edit dates or drag the slider to compare times, and handle daylight saving changes automatically. |
| System | Quick Shutdown | Quit selected apps before shutting down or restarting, with a cancellable five-second countdown, search, exclusion list, and force quit toggle. |
| System | Unattended Authorization | Verify and store your admin password in the local Keychain to approve matching Apple-signed system prompts during a timed or open session, leaving pre-existing and Privacy & Security prompts for manual confirmation. |

### Optional modules

Disabled by default; enable them from `功能模块…` in the top-right menu.

| Module | What it does |
| --- | --- |
| Weather | Shows current conditions in a selected city. Expand to see today's temperature range and the observation time from Open-Meteo. |
| Markets | Expand to see the Nasdaq-100, SOL in USD, and the USD/CNY reference rate with sources and quote times. Click again to collapse. |
| Tasks | View Apple Reminders in the Project group. Use the plus beside a list to add a task, click its title to edit, or click its circle to complete it. Open Reminders Connector from Tasks to set it up. Obsidian and the browser can use the same connection. The standalone connector currently requires Apple Silicon and macOS 27.2 or later. |
| Screenshot & Translation | Trigger window-snapping screen capture by hotkey, annotate with rectangles, arrows, or freehand ink, copy offline OCR text, translate in place via macOS Translation or a custom OpenAI-compatible endpoint, and pin scalable translucent stickers. |
| Window Drag | Grant Vorsmate Accessibility access, then hold Option and drag anywhere inside a movable window with the left mouse button. Choose a different modifier under Tools → Window Drag. |
| Xiaomi Remote | Place the built `VorsmateRemote.app` beside `Vorsmate.app` to map RC003 buttons to per-app shortcuts, gestures, and hold-to-repeat, with voice input via MiRemoteV 2ch. |

## Installation

### Requirements

macOS 14 or later on Apple Silicon or Intel (Universal binary). The app interface is currently in Simplified Chinese.

### Download installer

1. Download `Vorsmate-0.4.0.dmg` from [GitHub Releases](https://github.com/0xTotoroX/vorsmate/releases/tag/v0.4.0).
2. Open the disk image and drag `Vorsmate.app` into `Applications`.
3. Launch Vorsmate from Applications and click the gull icon in the menu bar.

### Updates and upgrades

Vorsmate checks a fixed signed update feed one minute after startup and every 12 hours, or manually from the top-right menu. Both the feed and disk image require valid signatures, and in-app updates preserve your settings and fan helper authorization.

If upgrading from `v0.3.2` or earlier, install `v0.4.0` or later manually once from GitHub Releases due to the installer filename change. In-app updates work normally after that.

### Build from source

Requires Xcode 26+ and the Swift 6 / macOS SDK.

```sh
git clone https://github.com/0xTotoroX/vorsmate.git
cd vorsmate
swift test
bash scripts/dev.sh
```

The default ad-hoc build supports input sources, audio devices, and fan monitoring. To enable fan speed control or build a universal disk image, pass an Apple signing identity:

```sh
VORSMATE_SIGN_IDENTITY='certificate name or fingerprint' bash scripts/build.sh --universal
bash scripts/package.sh
```

Release outputs go to `dist/`. See [CONTRIBUTING.md](CONTRIBUTING.md#本地开发) for development workflows and signing details.

## Usage

- Switching and reordering: Input sources and audio devices support Off, Automatic, and Locked modes. Expand a row to lock an item with a click or drag a row directly to reorder priorities; drop outside or press `Esc` to cancel. Audio apps with their own output or input picker should be set to the system default.
- Panel lifecycle and menu: Moving the pointer away closes the panel while background rules stay active. Launch at Login, `功能模块…`, Check for Updates, About, and Quit live in the top-right menu.
- Permissions and privacy: Fan speed control requires authorizing the bundled helper from the panel. Unattended Authorization requires Accessibility permission, and the admin password stays in the non-syncing local Keychain; Vorsmate never records audio or keystrokes.

## Documentation

- [Wireless microphones](docs/wireless-microphones.md)
- [Fan control rules](docs/fan-control.md)
- [Unattended Authorization](docs/unattended-auth.md)
- [Xiaomi Remote setup (Chinese)](docs/remote.md)
- [Update mechanism and publishing](docs/updates.md)
- [Menu bar design notes (Chinese)](DESIGN.md)

## Contributing and license

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines and report security issues through [SECURITY.md](SECURITY.md).

Licensed under the [MIT License](LICENSE). Third-party notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
