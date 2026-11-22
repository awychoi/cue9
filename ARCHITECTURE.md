# cue9 architecture

cue9 is a native macOS app in SwiftUI. It mirrors and drives a local DSH plugin: it polls the plugin, draws the companion’s face, edits the action-to-animation mapping, and flashes firmware. It is not a server, and it needs no account or cloud.

## Shape

```
DSH plugin (dsh-cue9-mote)
  ↕  local HTTP  ·  127.0.0.1:<dsh port>  ·  /plugins/cue9/*
AppModel
  ├─ NowView           live face, recent cues, local face previews
  ├─ FacesView         moment → face mapping and colours
  ├─ ClockWeatherView  timezone, city, units + device page previews
  ├─ ConnectView       DSH add-on, USB/Wi-Fi link, keep awake
  ├─ DeviceView        reactions, software, advanced
  ├─ PreviewEngine     → Cue9Preview (C, 360×360)
  ├─ FirmwareFlasher   → esptool / USB
  └─ ~/.dsh/cue9/{mapping,colours,colour-backgrounds,history,catalog}.json
```

The app has five destinations. **Now**, **Faces**, and **Clock & Weather** are the everyday pages; **Connect** and **Device** hold setup. When the plugin cannot be reached, Connect becomes the install guide and Now shows its offline face.

## Source map

| Path | Role |
|---|---|
| `app/Sources/Cue9App/` | SwiftUI app, state, DSH client, flasher, snapshots |
| `app/Sources/Cue9Preview/` | C face and clock/weather renderer used by the app previews |
| `firmware/` | ESP32-S3 firmware: panel, pages, shake, config |
| `pi/` | Raspberry Pi bridge (`cue9-moted`, `cue9-attach`) |
| `brand/decided/final/` | Lockups, icon, wordmark |

## DSH plugin contract

The plugin lives in a separate repository: [awychoi/dsh-cue9-mote](https://github.com/awychoi/dsh-cue9-mote).

| Call | Purpose |
|---|---|
| `GET /plugins/cue9/state` | Current state, action/animation lists, preview flag, agent/key counts |
| `POST /plugins/cue9/mapping` | Save the action → animation mapping |
| `POST /plugins/cue9/palette` | Save expression and background colours |
| `POST /plugins/cue9/behaviour` | Save shake sensitivity and reaction durations |
| `POST /plugins/cue9/preview` | Play one animation on the mote |
| `POST /plugins/cue9/live` | Return the mote to following DSH |
| `POST /plugins/cue9/usb` | Release or reconnect the USB bridge |
| `POST /plugins/cue9/link` | Switch between USB and Wi-Fi |

The app polls `/state` every 1.5 s. Mapping and colours are written locally first and posted best-effort, so the app keeps working when DSH is closed. DSH’s port changes per launch; the plugin writes its bound origin to `~/.dsh/cue9/dsh.json`, and the app switches to it when the saved address stops answering.

The plugin’s `actions` and `animations` lists drive the editor. The app caches them in `catalog.json`; on each load it reconciles additions, renames, and removals. Device-only reactions (shake, stroke) can be previewed and coloured but not mapped. Approvals and questions outrank those reactions.

## Behaviour

- **Live state** — sleep starts after five minutes without work; approvals and questions stay above it. A new session gets one wake beat. If the heartbeat stops, the mote falls back to its `hub` face.
- **History** — the last six cues are recorded locally in `history.json`; they are not fetched from DSH.
- **Preview** — the Now page follows DSH, while Faces selects an animation locally. “Show on cue9” sends that exact animation ID to the device.
- **Pages** — the mote holds three pages: face, clock, weather. Swipe or send `PAGE <0|1|2>`. An approval or question temporarily takes the screen; the page underneath is restored afterwards.
- **Clock and weather** — the Pi sends `TIME` every 15 s and `WX` every 15 minutes. Timezone, city, units, and 12/24-hour format are set under **Clock & Weather** in the app.

## Wireless path

The plugin can reach the mote through a Raspberry Pi instead of USB. The Pi runs `cue9-moted`: an mTLS listener for the mote and a local socket for attaches. The plugin starts `cue9-attach` over SSH with a key restricted to that command, so the user’s own SSH config is not involved.

The mote keeps its Wi-Fi credentials and TLS material in the `cue9cfg` partition. The app installs the Pi service, provisions the mote, and switches the plugin via `POST /plugins/cue9/link`. `~/.dsh/cue9/link.json` stores the current transport.

## Rendering and firmware

The face preview is a small C renderer producing a 360×360 frame at 30 fps. The clock and weather previews use the same `ambient.c` pages as the firmware, so the app shows the real device layout. The firmware keeps the same drawing code for the device.

`firmware.bin` is a merged image (bootloader, partition table, app). Before flashing, the app releases the USB bridge; it then runs `esptool` at `0x0` and reconnects the bridge. Colours and behaviour settings are sent at runtime, so they never require a rebuild.

## Build

`./app/Scripts/build-app.sh` builds with SwiftPM on macOS 14 or newer, bundles resources, renders the icon from `brand/decided/final/`, ad-hoc signs, and writes `app/build/cue9.app`.

See [README.md](README.md) for the overview and quick start.
