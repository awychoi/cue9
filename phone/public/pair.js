'use strict'

const connect = document.getElementById('connect')
const status = document.getElementById('status')
const notice = document.getElementById('notice')
const openApp = document.getElementById('open-app')

const url = new URL(window.location.href)
const token = url.searchParams.get('token') ?? ''

// The token is consumed by the POST below, never by this page load. Remove it
// from the address bar immediately so it is not left visible or in history.
if (url.searchParams.has('token')) {
  url.searchParams.delete('token')
  const clean = `${url.pathname}${url.search}${url.hash}`
  try {
    window.history.replaceState(null, '', clean)
  } catch { /* the URL still works */ }
}

let busy = false

function showNotice(message) {
  notice.textContent = message
  notice.hidden = false
}

function clearNotice() {
  notice.textContent = ''
  notice.hidden = true
}

function connected() {
  status.textContent = 'Connected. This Safari tab is paired.'
  status.classList.add('connected')
  connect.textContent = 'Connected'
  connect.disabled = true
  openApp.hidden = false
  clearNotice()
}

if (token.length === 0) {
  status.textContent = 'No pairing code.'
  connect.disabled = true
  showNotice('This link is missing its pairing code. Create a fresh link in cue9 on your Mac.')
} else {
  connect.addEventListener('click', async () => {
    if (busy) return
    busy = true
    connect.disabled = true
    connect.textContent = 'Connecting\u2026'
    status.textContent = 'Connecting\u2026'
    status.classList.remove('connected')
    clearNotice()

    try {
      const response = await fetch('/api/pair', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'content-type': 'application/json',
          'x-cue9-phone': '1',
        },
        body: JSON.stringify({ token }),
      })

      if (response.ok) {
        connected()
        return
      }

      status.textContent = 'Not connected.'
      if (response.status === 429) {
        showNotice('Too many attempts. Wait a few minutes, then create a fresh link.')
      } else if (response.status === 403) {
        showNotice('This link has expired or was already used. Create a fresh link in cue9 on your Mac.')
      } else {
        showNotice('That pairing link could not be used. Create a fresh link in cue9 on your Mac.')
      }
    } catch {
      status.textContent = 'Not connected.'
      showNotice('Could not reach your Mac. Check that cue9 is running, then try again.')
    } finally {
      busy = false
      if (!connect.disabled) connect.textContent = 'Connect'
      if (status.textContent === 'Not connected.') {
        connect.disabled = false
        connect.textContent = 'Try again'
      }
    }
  })
}
