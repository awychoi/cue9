import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pickLanAddress } from '../lib/config.js'
import { certificateInfo, setupStatus } from '../lib/setup.js'

function ipv4(address, overrides = {}) {
  return { address, family: 'IPv4', internal: false, ...overrides }
}

test('LAN selection prefers real private interfaces and skips virtual/CGNAT/link-local', () => {
  assert.equal(pickLanAddress({
    en0: [ipv4('203.0.113.5')],
    en1: [ipv4('192.168.1.10')],
    utun3: [ipv4('100.64.0.1')],
    awdl0: [ipv4('192.168.2.2')],
    en5: [ipv4('10.0.0.5')],
  }), '192.168.1.10')

  assert.equal(pickLanAddress({
    en0: [ipv4('10.0.0.2')],
    en1: [ipv4('192.168.1.3')],
  }), '10.0.0.2')

  assert.equal(pickLanAddress({
    en0: [ipv4('203.0.113.5')],
    en5: [ipv4('192.168.1.4')],
  }), '192.168.1.4')

  assert.equal(pickLanAddress({
    en0: [ipv4('100.64.1.2')],
    en1: [ipv4('169.254.10.1')],
    en2: [ipv4('192.168.1.8', { internal: true })],
    bridge0: [ipv4('192.168.1.9')],
  }), undefined)

  assert.equal(pickLanAddress({
    en0: [ipv4('172.20.1.1')],
    en1: [ipv4('172.32.0.1')],
  }), '172.20.1.1')

  assert.equal(pickLanAddress({
    en0: [ipv4('192.168.1.8')],
    en5: [ipv4('192.168.1.9')],
  }), '192.168.1.8')

  assert.equal(pickLanAddress({
    en0: [ipv4('192.168.1.8', { family: 4 })],
  }), '192.168.1.8')
})

function certificateFixture(days) {
  const dir = mkdtempSync(join(tmpdir(), 'cue9-cert-'))
  const cert = join(dir, 'cert.pem')
  const key = join(dir, 'key.pem')
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', String(days),
    '-subj', '/CN=cue9-test',
  ], { stdio: 'ignore' })
  return { dir, cert, key }
}

test('certificate status parses expiry, flags renewal, and never exposes the key', async t => {
  const short = certificateFixture(1)
  const long = certificateFixture(365)
  t.after(() => {
    rmSync(short.dir, { recursive: true, force: true })
    rmSync(long.dir, { recursive: true, force: true })
  })

  const shortInfo = certificateInfo(short.cert, short.key)
  assert.equal(shortInfo.ready, true)
  assert.match(shortInfo.expiresAt, /^\d{4}-\d{2}-\d{2}T/)
  assert.equal(shortInfo.daysRemaining, 0)
  assert.equal(shortInfo.renewSoon, true)

  const longInfo = certificateInfo(long.cert, long.key)
  assert.equal(longInfo.ready, true)
  assert.ok(longInfo.daysRemaining >= 300)
  assert.equal(longInfo.renewSoon, false)

  const missing = certificateInfo(join(short.dir, 'missing-cert.pem'), join(short.dir, 'missing-key.pem'))
  assert.deepEqual(missing, {
    ready: false,
    expiresAt: null,
    daysRemaining: null,
    renewSoon: true,
  })

  writeFileSync(short.key, 'PRIVATE KEY SENTINEL\n')
  const status = await setupStatus({
    config: { publicOrigin: 'https://phone.example:8443', port: 8791 },
    phone: { clients: new Set(), lastSeenAt: 0 },
    push: { hasSubscriptions: () => false },
    sessions: { listDevices: () => [] },
    paths: { certFile: short.cert, keyFile: short.key },
    deps: {
      tailscale: { running: true, online: true, dnsName: 'phone.example' },
      serve: true,
      lan: '192.168.1.10',
    },
  })

  assert.equal(status.https.ready, true)
  assert.equal(status.https.daysRemaining, 0)
  assert.equal(status.https.renewSoon, true)
  assert.equal(status.https.keyFile, undefined)
  assert.ok(!JSON.stringify(status).includes('PRIVATE KEY SENTINEL'))
  assert.equal(status.pairing.ready, true)
  assert.equal(status.localDns.address, '192.168.1.10')

  const noCert = await setupStatus({
    config: { publicOrigin: 'https://phone.example:8443', port: 8791 },
    phone: { clients: new Set(), lastSeenAt: 0 },
    push: { hasSubscriptions: () => false },
    sessions: { listDevices: () => [] },
    paths: { certFile: join(short.dir, 'missing-cert.pem'), keyFile: short.key },
    deps: {
      tailscale: { running: true, online: true, dnsName: 'phone.example' },
      serve: true,
      lan: '192.168.1.10',
    },
  })
  assert.equal(noCert.https.ready, false)
  assert.equal(noCert.https.expiresAt, null)
  assert.equal(noCert.https.daysRemaining, null)
  assert.equal(noCert.https.renewSoon, true)
  assert.equal(noCert.pairing.ready, false)
})
