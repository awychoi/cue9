---
treatment: hero
order: 40
kicker: Hardware · ESP32 · DSH
banner: docs/cue9-demo.jpg
banner_video: docs/cue9-demo.mp4
banner_alt: cue9 on a desk, cycling through its working, sleep, approval, question, and done faces on a round screen.
logo: brand/decided/final/cue9-lockup-white.svg
logo_light: brand/decided/final/cue9-lockup.svg
---

## How it started

Long coding sessions meant either constantly tabbing back to check progress or realizing hours later that an agent had been stalled on an approval. So I built cue9 so it budges me only when it needs me but I can still keep an eye on it if I want.

## What it is

cue9 pairs a DSH plugin, a Mac app, an ESP32 desk companion, and an iPhone approval pipeline so you can focus on other work while your agents run.

Status cues travel over SSH through a Raspberry Pi to drive the companion's animations, while native Apple push notifications route remote approvals to a home-screen web app over Tailscale / LAN. Acting on either clears the other automatically.