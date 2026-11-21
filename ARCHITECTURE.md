<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/decided/final/cue9-lockup-white.svg">
  <img src="brand/decided/final/cue9-lockup.svg" alt="cue9" width="240">
</picture>

# cue9 architecture

cue9 is a native macOS app in SwiftUI. It is a control surface, not a server: it polls a local DSH plugin, renders the mote’s face, edits the action-to-animation mapping, and flashes firmware when asked.

The app has two destinations: **Mote** and **Device**. Mote also holds the editor: **Edit** opens the mapping and colour inspector. Each animation has an expression colour and a screen background colour. DSH setup is a state of Device, not a separate page. If the plugin cannot be reached, Device becomes the install guide; if it can, Device shows the plugin, firmware, and Advanced sections.

```
DSH plugin (dsh-cue9-mote)
  ↕  local HTTP  ·  127.0.0.1:<dsh port>  ·  /plugins/cue9/*
AppModel
  ├─ MoteView          live face, recent cues, mapping/colour editor
  ├─ DeviceView        plugin, firmware, advanced
  ├─ PreviewEngine     → Cue9Preview (C, 360×360)
  ├─ FirmwareFlasher   → esptool / USB
  └─ ~/.dsh/cue9/{mapping,palette,backgrounds,history,catalog}.json
```

## Source map

| Path | Role |
|---|---|
| `app/Sources/Cue9App/AppModel.swift` | Observable state, catalog cache, 1.5 s polling, preview selection, persistence, cue history |
| `app/Sources/Cue9App/DSHClient.swift` | Typed HTTP client for the DSH plugin |
| `app/Sources/Cue9App/Models.swift` | Renderer colours, cue types, stored paths |
| `app/Sources/Cue9App/MoteView.swift` | Mote stage, live rail, mapping and colour inspector, preview |
| `app/Sources/Cue9App/AnimationTileView.swift` | Animation grid tile |
| `app/Sources/Cue9App/MoteColourPanel.swift` | Colour picker and HEX field |
| `app/Sources/Cue9App/DeviceView.swift` | Status strip, plugin/setup card, firmware, advanced |
| `app/Sources/Cue9App/RootView.swift` | Shell, sidebar, appearance, shared button styles |
| `app/Sources/Cue9App/Components.swift` | Brand assets, stage badge, links, checkboxes, byline |
| `app/Sources/Cue9App/Theme.swift` | Adaptive colour and type tokens |
| `app/Sources/Cue9App/PreviewEngine.swift` | Swift bridge to the C renderer; 30 fps frame loop |
| `app/Sources/Cue9App/PreviewSurface.swift` | `NSViewRepresentable` that displays frames |
| `app/Sources/Cue9Preview/` | C face renderer and baked font |
| `firmware/src/ambient.c` | Clock and weather pages, their own palettes and layout |
| `app/Sources/Cue9App/FirmwareFlasher.swift` | Port scan, esptool invocation, flash log |
| `app/Sources/Cue9App/Snapshot.swift` | Headless renderer used for screenshots |
| `app/Sources/Cue9App/Cue9App.swift` | App delegate, window, menu, snapshot flags |
| `app/Scripts/build-app.sh` | Release build, resources, icon, ad-hoc signing |
| `brand/decided/final/` | Lockups, icon, wordmark, favicon |

## DSH plugin contract

The plugin lives in a separate repository: [awychoi/dsh-cue9-mote](https://github.com/awychoi/dsh-cue9-mote).

| Call | Purpose |
|---|---|
| `GET /plugins/cue9/state` | Current state, the plugin’s action/animation list, preview flag, agent/key counts, USB status |
| `POST /plugins/cue9/mapping` | Save the action → animation mapping |
| `POST /plugins/cue9/palette` | Save expression and background colours |
| `POST /plugins/cue9/preview` | Play one animation on the mote (`{action, animation}`) |
| `POST /plugins/cue9/live` | Return the mote to following DSH |
| `POST /plugins/cue9/usb` | Release or reconnect the USB bridge |

The app sets `x-cue9-action: 1` on posts. Mapping and colours are written locally first, so the app still works when DSH is closed; the post is best-effort.

DSH's web port is assigned per launch. The plugin writes its bound origin to `~/.dsh/cue9/dsh.json`; when the saved address stops answering, the app reads that file, validates `/state`, and switches to it.

The plugin’s `actions` and `animations` arrays are the source of truth for the editor. The app caches the last list in `~/.dsh/cue9/catalog.json` so the real labels survive DSH being closed. The existing 1.5 s `/state` poll carries the lists; there is no separate refresh request.

When the list changes, the app reconciles it with the cache. An action that disappears loses its mapping. A renamed action (same id, new label) keeps its mapping. A newly added action starts with nothing mapped after the first catalog load; the plugin’s default map is only a suggestion. Animations that disappear are dropped from mappings. The `offline` face stays in the animation list so it can be assigned or previewed even though no default action uses it.

## Wireless path

The plugin can reach the mote through a Raspberry Pi instead of USB. The Pi runs
`cue9-moted`: an mTLS listener for the mote and a UNIX socket for attaches. The
plugin starts `cue9-attach` over SSH and keeps the same newline protocol. The
service sends `ALIVE` only while a Mac is attached, so a stale face never claims
work is still running.

The mote holds its Wi-Fi credentials, the Pi's CA and its own client key in the
`cue9cfg` partition. The cue9 app installs the Pi service, flashes that partition,
and switches the plugin with `POST /plugins/cue9/link`. The app installs a
dedicated SSH key restricted to `cue9-attach`; the plugin connects with that key
and `-F /dev/null`, so the user's own agent and config are not involved. The body
framebuffer lives in PSRAM and is fed to the panel through a 90-row internal DMA
stage.

## State and status

- `dshOnline` means the plugin’s state endpoint answered. It is not a check that the DSH process is alive.
- `Mote` comes from the plugin’s USB status when available. If the plugin is unreachable, the app falls back to scanning `/dev/cu.usbmodem*`, so the Device page can say “USB found” while the plugin is offline.
- `hub_down` is the current state while the USB bridge is disconnected. The mote also falls back to its `hub` scene when the heartbeat stops, so a sleeping Mac is covered on the device even though the app cannot observe it.
- `sleep` is triggered by the plugin after five minutes without a running agent; pending approvals/questions stay above it.
- Keys are a live count, not an action: the plugin counts running sessions and subagents every 500 ms, keeps the most recently active session on the cat, and sends `AGENTS n` for the extras. Work in any session claims the cat; a completion does not interrupt another running session. A turn made only of a background-job notice settles to idle without a done beat. The app decodes `agents`/`keys` but does not map them.
- Recent cues are recorded locally when the action or animation changes. The list keeps six entries and is stored in `history.json`; it is not fetched from DSH.
- `lastSaved` is the small “Saved” confirmation in the Mote editor.

## Ambient pages

Clock and weather are device pages, not Pip states. The mote holds three pages: the live face,
the clock, and the weather. A horizontal swipe on the touch controller steps through them, and
`PAGE <0|1|2>` does the same from the host link. While a page is showing, the live scene keeps
running underneath, so swiping back is seamless.

The clock arrives once per quiet episode: after 60 s in `sleep` or `hub`, the mote shows it without
a cue. A swipe ends the auto step for that episode. The chosen page otherwise stays put: work, done
and idle cues never pull it back. Only an approval or question takes the screen; the page it
interrupted is remembered and restored when that cue clears. A swipe during the cue cancels the
restore.

The Pi feeds the pages. `cue9-moted` sends `TIME <epoch> <tz_offset_min> <12|24>` every 15 s and
`WX <icon>|<temp>|<hi>|<lo>|<feels>|<F|C>|<city>` every 15 minutes (Open-Meteo). The offset comes
from the app's chosen zone when there is one, otherwise from the Pi's own timezone. The city comes
from `moted.json`, or from the Pi's own timezone; `cue9_pi_setup.sh` keeps that block when it
re-runs. The weather arc maps the day's low and high onto the bezel on a fixed scale (10–100 °F,
−15–40 °C), with a dot at the current temperature. The mote has no RTC: it counts from the last
`TIME` and boots at 1970 until a sync arrives. Ambient lines are data, not agent state, so they
never refresh the Mac liveness clock and never appear in the attach replay.

The app's Device page has an **Ambient** card: a timezone picker, a city search (Open-Meteo's
geocoder), units, and 12/24-hour format. It reads the Pi's block from the bridge status line and
saves with `AMBIENT <json>` over the same restricted SSH key the plugin uses. `cue9-moted` validates
it, applies it live, writes `moted.json`, and acknowledges only to that attach connection. The last
confirmed settings are cached locally, so the card still opens with them when the Pi is away.

## Preview renderer

`Cue9Preview` is a small C drawing library. `PreviewEngine` owns it on a serial queue and renders a 360×360 RGB565 frame at 30 fps. Swift converts the frame to RGBA and hands it to `PreviewSurface` (`NSImageView`), clipped to the screen circle.

The sequence resets at the same boundary as the device: 5 seconds for the three typing takes (`work`, `workCrazy`, `workAnnoyed`), 6 seconds for the others. The expression and background colours are passed into the renderer. The Mote screen follows DSH; the editor selects an animation locally and previews it. “Test on mote” sends the selected animation ID, so the mote plays exactly the face in the preview rather than a random animation from that action’s mapping.

## Firmware

The app bundles `firmware.bin` in its resources. `FirmwareFlasher` scans the USB modem ports and invokes `esptool` with:

```
--chip esp32s3 -p <port> -b 460800 write_flash 0x10000 firmware.bin
```

Before flashing, `AppModel.flashFirmware()` releases the DSH USB bridge and waits for the port to become free. After flashing, it reconnects the bridge. The bootloader and partition table are not touched. Missing `esptool` or a held port is reported in the Device firmware card.

The firmware takes `COLOR <animation> <hex>` and `BG <animation> <hex>` over USB. Both are staged and applied when that animation next starts. They live in RAM; the plugin re-sends the full palette and background set whenever the bridge connects.

The battery glyph uses the same colour for its shell and bars (green, yellow, red), and a valid battery always shows at least one red bar. It sits at the top edge on the live face and inside the seconds ring on the clock page; the weather page goes without. The body buffer covers all 360 rows, so the clock's ring and the weather's arc can use the bezel. The baked font carries a 64 px face for the time and temperature, plus U+00B0 and U+00B7. At 5 % or below with no charge current, the firmware drops the panel rail and deep-sleeps for 30 s instead of booting into a brown-out loop. After a low-battery sleep it stays dark across retries until it sees charge current or the gauge is above 10 %, then it boots normally.

## Build and assets

- SwiftPM package: `app/Package.swift`; macOS 14; executable `cue9`.
- `app/Scripts/build-app.sh` performs the release build, copies the app resources, renders the `.icns` from `brand/decided/final/cue9-icon.svg`, writes `Info.plist`, ad-hoc signs, and produces `app/build/cue9.app`.
- The lockups use the Big C ratio: 42 px mark, 94 px wordmark, 7 px gap at app size. The source SVGs live in `brand/decided/final/`; the app copies them into its resources.
- `Snapshot.swift` can render a section headlessly with `--snapshot`, `--snapshot-section`, and `--snapshot-appearance`; it is how `docs/cue9-mote.png` was made.
- The app’s UI is Inter with adaptive paper/surface/ink tokens and an orange accent. The sidebar carries the by-wychoi credit.

## Boundaries

- The app cannot install the DSH plugin. DSH installs local plugins through **Plugins → Add plugin**; the Device guide tells the user exactly that.
- The DSH plugin, firmware sources, and hardware research are not required to build or run this app. The built app carries its own firmware image and preview renderer.
- The app is local-only: no account, no cloud, no remote service.

See [README](README.md) for the overview and [SETUP](SETUP.md) for installation.
