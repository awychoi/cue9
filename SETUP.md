# cue9 setup

## What you need

- macOS 14 or newer
- Xcode command line tools (Swift 5.9 or newer)
- DeepSeek Harness (DSH)
- The cue9 mote, connected over USB — optional for the app, required for the face
- `esptool.py` — only if you want to flash firmware

## 1. Build the app

From the repository root:

```bash
./app/Scripts/build-app.sh
open app/build/cue9.app
```

The script builds with SwiftPM, bundles the resources, renders the app icon from the brand SVG, ad-hoc signs the app, and writes `app/build/cue9.app`. `app/build/` is not tracked.

## 2. Install the DSH plugin

The app is the control surface; the plugin is what talks to DSH.

1. Get the plugin folder from [awychoi/dsh-cue9-mote](https://github.com/awychoi/dsh-cue9-mote).
2. In DSH, open **Plugins → Add plugin** and choose the `dsh-cue9-mote` folder.
3. Leave DSH running. cue9 checks it every 1.5 seconds; the Device page reports when it is connected.

DSH does not allow another app to install a plugin silently. The Device page shows the same steps, with an **Open DSH** button, when the plugin is not connected.

## 3. First run

- Open cue9. It finds the plugin's current DSH port automatically; if it cannot, set the address under **Advanced**.
- If it does not, open **Device**. The setup guide is the first thing on the page.
- If DSH runs on a different address, open **Advanced** on Device, change the DSH address, and press **Apply**.
- The sidebar shows two facts separately: the **mote** (through the plugin, or a direct USB port scan) and the **DSH plugin** (whether the app can reach it).

The app stores your mapping, expression colours, background colours, and recent cue history in:

```
~/.dsh/cue9/
```

Deleting `history.json` clears the recent list. Deleting `palette.json`, `backgrounds.json`, and `mapping.json` returns the app to the defaults.

## 4. Firmware (optional)

The app bundles `firmware.bin`. To flash:

1. Install `esptool` so it is available at one of the paths the app checks, or in the ESP-IDF toolchain.
2. Connect the mote over USB.
3. Open **Device → Firmware**, choose the `/dev/cu.usbmodem…` port, and press **Flash firmware…**.
4. Do not unplug the mote while it is flashing.

The app releases the DSH USB bridge before flashing, writes the merged image
(bootloader, partition table, app) at `0x0`, resets the board, and reconnects the
bridge afterwards.

## 5. Wireless (optional)

The mote can reach DSH through a Raspberry Pi instead of USB.

1. Open **Device → Link**, choose **Wi-Fi**, and press **Set up Pi…**.
2. Enter the Pi's SSH host (`pi@192.168.1.x`) and its password once, or install your key first.
3. Connect the mote over USB and press **Provision mote…**. Enter the Wi-Fi network and password.
4. The app flashes the `cue9cfg` partition, switches the plugin to Wi-Fi, and the mote dials the Pi.
5. The clock and weather pages come from the Pi. Open **Device → Ambient** to set the timezone, city, °F/°C, and 12/24-hour clock, then **Save to Pi**.

The Pi service (`cue9-moted`) keeps the mTLS link; `~/.dsh/cue9/link.json` stores
the transport. The plugin runs `caffeinate` while loaded, so the Mac stays reachable
when its dock is switched away. The Pi needs Python 3 and `openssl`, no extra packages.

## Troubleshooting

**Device says the DSH plugin is not connected.** DSH may be closed, the plugin may not be installed, or the address may be wrong. Open DSH and try **Plugins → Add plugin** again. The app cannot install the plugin for you.

**The mote is “USB found” but the plugin is not connected.** The app can see a USB modem, but it has no DSH state. You can still flash firmware from Device. The Mote page stays offline until the plugin connects.

**No USB port is listed.** Check the cable, press the refresh button next to the port menu, and make sure no other process is holding the port.

**Build fails.** Confirm macOS is 14+, `swift --version` works, and Xcode command line tools are installed. Run the build from the repository root so the brand assets and resources resolve.

**I want the old colours back.** Delete `~/.dsh/cue9/palette.json` and `~/.dsh/cue9/backgrounds.json` and relaunch the app.

## More

- [README](README.md) — what the app is
- [ARCHITECTURE](ARCHITECTURE.md) — how it works under the hood
- [DSH plugin](https://github.com/awychoi/dsh-cue9-mote) — the host adapter
