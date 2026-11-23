#!/usr/bin/env node
/**
 * Status/fallback setup for the cue9 phone bridge.
 *
 * It uses the Mac's own Tailscale hostname for both paths:
 *   - away:     Tailscale MagicDNS -> tailnet IP
 *   - at home:  your local DNS   -> the Mac's LAN IP
 * The certificate is valid for the name, so the same URL and session work on
 * both. Nothing is exposed publicly; Tailscale Serve is tailnet-only.
 *
 * This script never prints or writes a pairing token. Open the cue9 app to
 * mint a one-time pairing QR after the phone surface is ready.
 *
 * Usage: node setup.mjs [--apply]
 */
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { loadConfig } from './lib/config.js'
import { applySetup, setupStatus } from './lib/setup.js'

const APPLY = process.argv.includes('--apply')

function log(line = '') { console.log(line) }

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return {} }
}

const config = loadConfig()
let status = await setupStatus({ config, phone: null, push: null, sessions: null })

if (status.tailscale?.running !== true || status.tailscale?.online !== true) {
  log('Tailscale is not connected on this Mac.')
  log('')
  log('1. Open Tailscale and connect this Mac.')
  log('2. If HTTPS certificates are not enabled, turn them on in the Tailscale')
  log('   admin DNS page (the cue9 app opens it for you too).')
  log('3. Run this again: node setup.mjs')
  process.exit(1)
}

if (APPLY) {
  await applySetup({ config })
  status = await setupStatus({ config, phone: null, push: null, sessions: null })
}

log('')
if (APPLY) log(`Updated ${config.configPath}`)
else log(`Config: ${config.configPath}`)
log('')
log('Next:')
log('1. Add this local DNS record on your router or Pi-hole:')
log(`     ${status.localDns.name}  ->  ${status.localDns.address}`)
log('   (Reserve the Mac’s LAN IP so it does not change.)')
log('   If you keep Tailscale on, you can skip this step.')
if (status.serve?.active === true) {
  log(`2. Tailscale Serve is active at ${status.serve.url}.`)
} else {
  log('2. Finish the phone link from the cue9 app, or run:')
  log('     node setup.mjs --apply')
}
log('3. Restart DeepSeek Harness after the app finishes setup.')
log('4. Open cue9 → Connect → Approvals on your phone → Set up phone.')
log('   The app creates a one-time pairing QR. No pairing token is printed.')
log('')
log('The HTTPS listener stays on the LAN only; Tailscale Serve stays tailnet-only.')
log('Do not use Funnel.')

const profile = process.env.DSH_PROFILE ?? 'desktop'
const profilePkg = readJson(join(homedir(), '.dsh', 'profiles', profile, 'package.json'))
const bundles = profilePkg?.dsh?.profile?.bundles ?? []
const phoneIndex = bundles.indexOf('dsh-cue9-phone')
const moteIndex = bundles.indexOf('dsh-cue9-mote')
if (phoneIndex >= 0 && moteIndex >= 0 && phoneIndex > moteIndex) {
  log('')
  log('Warning: the cue9 phone bundle must load before cue9-mote so the mote')
  log('still sees approvals/questions. Reinstall cue9-mote after cue9-phone,')
  log('or move dsh-cue9-phone above dsh-cue9-mote in the profile bundle list.')
}
