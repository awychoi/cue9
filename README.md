<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/decided/final/cue9-lockup-white.svg">
  <img src="brand/decided/final/cue9-lockup.svg" alt="cue9" width="286">
</picture>


**A quiet control surface for a DSH-powered desktop companion. (currently supports the ESP-32 Vocat/ Echoear)**

cue9 shows what DeepSeek Harness is doing on the companion’s round screen, and lets you choose the face for each action. It also brings DSH plugin setup and firmware flashing into one Mac app.

![The cue9 Mote view, following DSH](docs/cue9-mote.png)

*Companion view, following DSH.*

![The cue9 demo on a real device: working, sleep, approval, question, and done](docs/cue9-demo.webp)

*Real device: working, sleep, approval, question, and done.*

## What it does

- **Mote** — or emotions - watch the face follow DSH, with the current cue and a short local history. Open **Edit** to map actions to animations, change expression and background colours, and test a face on the mote.
- **Link** — USB, or Wi-Fi through a Raspberry Pi bridge.
- **App** — Everything from DSH plugin setup, firmware flashing, connection status, and advanced settings.

## Get it running

1. Install the DSH plugin. Download [dsh-cue9-mote](https://github.com/awychoi/dsh-cue9-mote), then in DSH open **Plugins → Add plugin** and choose the folder.
2. Build the app on macOS 14 or newer:
   ```bash
   ./app/Scripts/build-app.sh
   open app/build/cue9.app
   ```
3. Open **Device** if the plugin is not detected. cue9 finds DSH's current local port automatically; the address can still be set under **Advanced**.

More details in [SETUP.md](SETUP.md).

## Technical

The app structure, DSH API contract, preview renderer, storage, and firmware path are in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

GPL-3.0. See [LICENSE](LICENSE). Copyright © 2026 awychoi.

The bundled firmware is built with Espressif ESP-IDF and the Apache-2.0 ST77916 panel driver. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Inter is bundled under the SIL Open Font License; see [Inter-OFL.txt](app/Sources/Cue9App/Resources/Inter-OFL.txt).

---

Ideation and design by [wychoi](https://wychoi.com), created agentically.
