# Codex Local Meter App

Native macOS menu bar version of the Codex Local Meter VS Code extension. It reads local Codex session files under `~/.codex`, derives usage metadata, and can optionally fetch current account rate limits through the local Codex App Server.

Reported account limits retain Codex's `Primary` and `Secondary` names; the app does not assume that Primary means five hours or Secondary means seven days. Current configurations may report only a Primary weekly limit. Fixed 5-hour and 7-day token/message totals are shown separately as local activity estimates.

## Privacy

- No network calls by default.
- No telemetry or analytics.
- No writes to Codex session files.
- No prompt, response, code, or tool-output content shown.

Live account telemetry is off by default. When enabled in Details, the app asks the authenticated local `codex app-server` for account rate-limit metadata during refresh. This does not start a model turn or send session content, but the Codex App Server may make an authenticated service request.

## Development

Run the local parity harness:

```bash
swift run CodexLocalMeterCoreTests
```

Run SwiftPM's package check:

```bash
swift test
```

Build the app executable:

```bash
swift build
```

Package a local `.app` bundle:

```bash
./scripts/package-app.sh
```

The bundle is written to `dist/Codex Local Meter.app`.

## Run from `dist`

After packaging, launch the menu bar app from Finder by opening:

```text
dist/Codex Local Meter.app
```

Or launch it from Terminal:

```bash
open "dist/Codex Local Meter.app"
```

The app runs as a menu bar utility, so it does not open a Dock window. Look for the Codex usage text in the macOS menu bar.

## Install to User Applications

After packaging, install the app into `~/Applications`:

```bash
./scripts/install-app.sh
```

The installer always rebuilds and packages the current source before replacing the installed app, so an older `dist` bundle cannot be installed accidentally.

Then launch the installed app:

```bash
open "$HOME/Applications/Codex Local Meter.app"
```

If macOS says the app is already running, quit the menu bar copy first and run the install command again.

## Troubleshooting

### App is running but not visible in the menu bar

macOS can hide third-party menu bar utilities even when the app is running and has created its `NSStatusItem` correctly. Check:

```text
System Settings -> Menu Bar -> Allow in the Menu Bar -> Codex Local Meter
```

Make sure **Codex Local Meter** is enabled. If this setting is off, the process may appear in Activity Monitor and the app log may show status item updates, but nothing will appear in the menu bar.

Development note: this was mistaken at first for an app lifecycle or `NSStatusItem` rendering issue. The app was logging updates such as `status item updated title=...`, but macOS was suppressing the item until the Menu Bar permission was enabled.
