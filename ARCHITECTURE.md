# cue9 architecture

cue9 is a native SwiftUI app that mirrors and drives a local DSH plugin: it polls the plugin,
draws the companion’s face, edits the action-to-animation mapping, and flashes firmware. There
is no server, account, or cloud.

```
DSH plugin (dsh-cue9-mote)
  ↕ local HTTP · 127.0.0.1:<port> · /plugins/cue9/*
AppModel
  ├─ Now, Faces, Clock & Weather   everyday pages
  ├─ Connect, Device               setup, USB/Wi-Fi, firmware
  ├─ PreviewEngine → Cue9Preview (C, 360×360)
  └─ ~/.dsh/cue9/*.json
```

| Path | Role |
|---|---|
| `app/Sources/Cue9App/` | SwiftUI app, state, DSH client, flasher, snapshots |
| `app/Sources/Cue9Preview/` | C face, clock, and weather renderer for previews |
| `firmware/` | ESP32-S3 firmware: panel, pages, shake, config |
| `pi/` | Raspberry Pi bridge (`cue9-moted`, `cue9-attach`) |
| `brand/decided/final/` | Lockups, icon, wordmark |

## DSH plugin

The plugin lives in [awychoi/dsh-cue9-mote](https://github.com/awychoi/dsh-cue9-mote).

| Call | Purpose |
|---|---|
| `GET /plugins/cue9/state` | State, action/animation lists, agent counts |
| `POST /plugins/cue9/mapping` | Action → animation mapping |
| `POST /plugins/cue9/palette` | Expression and background colours |
| `POST /plugins/cue9/behaviour` | Shake sensitivity and reaction durations |
| `POST /plugins/cue9/preview` | Play one animation on the mote |
| `POST /plugins/cue9/live` | Return the mote to following DSH |
| `POST /plugins/cue9/usb` | Release or reconnect the USB bridge |
| `POST /plugins/cue9/link` | Switch between USB and Wi-Fi |

The app polls `/state` every 1.5 s. Mapping and colours are stored locally first and posted
best-effort, so the app keeps working with DSH closed. DSH’s port changes per launch; the plugin
records its origin in `~/.dsh/cue9/dsh.json`, and the app follows it.

`actions` and `animations` drive the editor; the app caches them in `catalog.json` and reconciles
changes on load. Shake and stroke can be previewed and coloured but not mapped.

## Behaviour

- **Priority** — approvals and questions outrank everything. Sleep starts after five minutes
  without work; a new session gets one wake beat; a lost heartbeat falls back to `hub`.
- **Pages** — face, clock, weather. Swipe or send `PAGE <0|1|2>`. Attention takes the screen
  temporarily, then restores the page underneath.
- **Clock and weather** — the Pi sends `TIME` every 15 s and `WX` every 15 minutes. The app sets
  timezone, city, units, and clock format.

## Wireless path

The Pi runs `cue9-moted`: an mTLS listener for the mote and a local socket for attaches. The
plugin starts `cue9-attach` over SSH with a key restricted to that command, so the user’s SSH
config is untouched. The mote keeps Wi-Fi credentials and TLS material in the `cue9cfg`
partition. The app installs the Pi service, provisions the mote, and switches transport via
`/plugins/cue9/link`; `link.json` stores the current choice.

## Firmware

The app preview uses the same C code as the device: a 360×360 face at 30 fps, and `ambient.c`
for the clock and weather pages. `firmware.bin` is a merged image (bootloader, partition table,
app). The flasher releases the USB bridge, runs `esptool` at `0x0`, and reconnects. Colours and
behaviour are sent at runtime, so they never need a rebuild.

## Build

`./app/Scripts/build-app.sh` builds with SwiftPM on macOS 14+, bundles resources, renders the
icon, ad-hoc signs, and writes `app/build/cue9.app`. See [README.md](README.md) for the overview.
