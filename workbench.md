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

During long coding sessions, I was either babysitting the tab or discovering hours later that an agent had stalled on an approval. I built cue9 so it nudges me only when I'm needed, with a glanceable view if I want to check in.

## What it is

cue9 pairs a DSH plugin, a Mac app, a raspberry pi host, an ESP32 desk companion, and an iPhone approval pipeline so you can focus on other work while your agents run.

Status cues travel over SSH through a Raspberry Pi to drive the companion's animations, while native Apple push notifications route remote approvals to a home-screen web app over Tailscale / LAN. Acting on either clears the other automatically.