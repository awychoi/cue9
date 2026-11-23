/** Automatic sleep assertion for cue9: awake only while DSH is working or waiting. */
import { spawn } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DIR = join(homedir(), '.dsh', 'cue9', 'phone')
const PREF_PATH = join(DIR, 'power.json')
const LINGER_MS = 15_000

function readPref() {
  try {
    const value = JSON.parse(readFileSync(PREF_PATH, 'utf8'))
    return value?.enabled !== false
  } catch {
    return true
  }
}

function writePref(enabled) {
  mkdirSync(DIR, { recursive: true, mode: 0o700 })
  writeFileSync(PREF_PATH, `${JSON.stringify({ enabled }, null, 2)}\n`, { mode: 0o600 })
}

/**
 * Owns the automatic keep-awake.
 * @param {{ ctx: object, store: object, log?: Function }} options
 */
export function createPower({ ctx, waiting: waitingCount = () => 0, log = console.log }) {
  let enabled = readPref()
  let working = 0
  let waiting = 0
  let lastBusyAt = 0
  let process_ = null
  let origin
  let legacyDisabled = false

  function reason() {
    if (waiting > 0) return waiting === 1 ? 'Waiting for your answer' : `${waiting} requests waiting`
    if (working > 0) return working === 1 ? '1 agent working' : `${working} agents working`
    return 'Idle'
  }

  function keep() {
    return enabled && (working > 0 || waiting > 0 || Date.now() - lastBusyAt < LINGER_MS)
  }

  function start() {
    if (process_ !== null) return
    try {
      const child = spawn('/usr/bin/caffeinate', ['-i', '-s', '-w', String(process.pid)], { stdio: 'ignore' })
      process_ = child
      child.on('exit', () => {
        if (process_ === child) process_ = null
      })
    } catch (error) {
      process_ = null
      log(`[cue9-phone] sleep assertion unavailable: ${error?.message ?? error}`)
    }
  }

  function stop() {
    if (process_ === null) return
    const child = process_
    process_ = null
    try {
      child.removeAllListeners('exit')
      child.kill()
    } catch { /* already gone */ }
  }

  function sync() {
    if (keep()) start()
    else stop()
  }

  function sample() {
    const registry = ctx.get('agents')
    const live = typeof registry?.list === 'function' ? registry.list() : []
    working = live.filter(agent => agent?.status === 'running').length
    waiting = waitingCount()
    if (working > 0 || waiting > 0) lastBusyAt = Date.now()
    sync()
  }

  function state() {
    return {
      enabled,
      active: process_ !== null,
      working,
      waiting,
      reason: reason(),
    }
  }

  function setEnabled(value) {
    enabled = value === true
    writePref(enabled)
    if (!enabled) stop()
    else sync()
    void disableLegacy()
    return state()
  }

  function attachOrigin(value) {
    origin = value
    void disableLegacy()
  }

  /** The old cue9-mote plugin owns its own caffeinate. Turn that one off once. */
  async function disableLegacy() {
    if (origin === undefined || legacyDisabled) return
    try {
      const response = await fetch(`${origin}/plugins/cue9/state`, { signal: AbortSignal.timeout(1500) })
      if (!response.ok) return
      const state = await response.json()
      if (state?.link?.keepAwake === false) {
        legacyDisabled = true
        return
      }
      const transport = typeof state?.link?.transport === 'string' ? state.link.transport : 'usb'
      await fetch(`${origin}/plugins/cue9/link`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-cue9-action': '1' },
        body: JSON.stringify({ transport, keepAwake: false }),
        signal: AbortSignal.timeout(2000),
      })
      legacyDisabled = true
    } catch { /* the old plugin may not be mounted; try again next time */ }
  }

  const interval = setInterval(sample, 1000)
  interval.unref?.()
  sample()

  return {
    state,
    setEnabled,
    attachOrigin,
    sample,
    dispose() {
      clearInterval(interval)
      stop()
    },
  }
}
