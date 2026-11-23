/** cue9 phone surface: pending DSH approvals and questions, mobile first. */

const state = {
  requests: [],
  activeId: null,
  busy: false,
  connected: false,
  pairing: false,
  error: '',
  pairText: '',
  pairError: '',
  draft: null,
  draftFor: null,
}

const main = document.getElementById('main')
const toastEl = document.getElementById('toast')
const dot = document.getElementById('dot')
const statusText = document.getElementById('statusText')
let source
let toastTimer
let lastAuthCheck = 0

const alertState = {
  status: 'checking',
  permission: typeof Notification !== 'undefined' ? Notification.permission : 'unsupported',
  key: null,
  registration: null,
  subscription: null,
  busy: false,
  probing: false,
  revision: 0,
  disabled: false,
  error: '',
}

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag)
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value === undefined || value === null || value === false) continue
    if (key === 'class') node.className = value
    else if (key === 'text') node.textContent = value
    else if (key === 'dataset') Object.assign(node.dataset, value)
    else if (key === 'checked' || key === 'disabled' || key === 'value' || key === 'hidden') node[key] = value
    else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2), value)
    else node.setAttribute(key, value === true ? '' : value)
  }
  for (const child of children.flat(Infinity)) {
    if (child === undefined || child === null || child === false) continue
    node.append(child instanceof Node ? child : document.createTextNode(String(child)))
  }
  return node
}

function markSvg() {
  const original = document.querySelector('.mark svg')
  return original ? original.cloneNode(true) : el('svg', { viewBox: '0 0 1024 1024' })
}

function codeOf(request) {
  if (typeof request.command === 'string' && request.command.length > 0) return request.command
  if (request.args === undefined) return ''
  try { return JSON.stringify(request.args, null, 2) } catch { return String(request.args) }
}

function claimOf(request) {
  return {
    reqId: request.reqId,
    sessionId: request.sessionId ?? null,
    callId: request.callId ?? null,
  }
}

function staleMessage(status) {
  return status === 404 ? 'Already handled.' : 'This request changed; refresh.'
}

function toast(message, duration = 2600) {
  toastEl.textContent = message
  toastEl.hidden = false
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toastEl.hidden = true }, duration)
}

function setStatus() {
  dot.classList.toggle('on', state.connected)
  statusText.textContent = state.pairing ? 'pairing' : state.connected ? 'connected' : 'connecting'
}

async function api(path, options = {}) {
  const headers = { 'x-cue9-phone': '1', ...(options.body ? { 'content-type': 'application/json' } : {}), ...(options.headers ?? {}) }
  const response = await fetch(path, {
    credentials: 'same-origin',
    ...options,
    headers,
  })
  let data = null
  try { data = await response.json() } catch { /* empty body */ }
  if (response.status === 401) {
    disconnect()
    if (!state.pairing) {
      state.pairing = true
      state.busy = false
      state.error = ''
      setStatus()
      render()
    }
  }
  return { response, data }
}

async function ack(request) {
  if (request === undefined || state.pairing) return
  try {
    const { response } = await api('/api/ack', {
      method: 'POST',
      body: JSON.stringify(claimOf(request)),
    })
    if (response.status === 401) return
    if (response.status === 404 || response.status === 409) {
      dropStale(request, response.status)
    }
  } catch { /* best effort */ }
}

function ensureDraft(request) {
  if (request === undefined || request.kind !== 'question') {
    state.draft = null
    state.draftFor = null
    return
  }
  if (state.draftFor === request.reqId && state.draft !== null) return
  const draft = {}
  for (const question of request.questions ?? []) draft[question.id] = { selected: [], custom: '' }
  state.draft = draft
  state.draftFor = request.reqId
}

function activeRequest() {
  return state.requests.find(request => request.reqId === state.activeId) ?? state.requests[0]
}

function select(reqId) {
  state.activeId = reqId
  state.error = ''
  ensureDraft(activeRequest())
  if (history.replaceState) history.replaceState(null, '', `#/r/${encodeURIComponent(reqId)}`)
  render()
}

function removeRequest(reqId) {
  state.requests = state.requests.filter(request => request.reqId !== reqId)
  if (state.activeId === reqId) {
    state.activeId = state.requests[0]?.reqId ?? null
    state.error = ''
    ensureDraft(activeRequest())
  }
  if (location.hash === `#/r/${encodeURIComponent(reqId)}` && history.replaceState) {
    history.replaceState(null, '', '/')
  }
  render()
}

function dropStale(request, status) {
  removeRequest(request.reqId)
  toast(staleMessage(status))
}

function syncQuestion(qid) {
  const value = state.draft?.[qid]
  if (value === undefined) return
  for (const option of document.querySelectorAll('.opt')) {
    if (option.dataset.qid !== qid) continue
    const on = value.selected.includes(option.dataset.label)
    option.classList.toggle('on', on)
    const input = option.querySelector('input')
    if (input) input.checked = on
  }
  const custom = document.querySelector(`[data-custom="${cssEscape(qid)}"]`)
  if (custom !== null && custom.value !== value.custom) custom.value = value.custom
}

function cssEscape(value) {
  if (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') return CSS.escape(value)
  return String(value).replace(/["\\]/g, '\\$&')
}

async function answer(request, payload) {
  state.busy = true
  state.error = ''
  render()
  try {
    const { response, data } = await api('/api/answer', {
      method: 'POST',
      body: JSON.stringify({ ...claimOf(request), ...payload }),
    })
    state.busy = false
    if (response.status === 401) return { ok: false, auth: true }
    if (response.status === 404 || response.status === 409) {
      dropStale(request, response.status)
      return { ok: true, stale: true }
    }
    if (response.ok) {
      removeRequest(request.reqId)
      toast('Sent to DSH.')
      return { ok: true }
    }
    state.error = data?.error === 'invalid-answer' ? 'That answer is not valid.' : 'Could not send. Try again.'
    toast(state.error)
    render()
    return { ok: false, data }
  } catch {
    state.busy = false
    state.error = 'Could not reach your Mac. Try again.'
    toast(state.error)
    render()
    return { ok: false }
  }
}



function metaOf(request) {
  if (typeof request.cwd === 'string' && request.cwd.length > 0) return request.cwd
  return request.sessionId ?? ''
}

function renderEmpty() {
  main.replaceChildren(el('div', { class: 'empty' },
    el('div', { class: 'face' }, markSvg()),
    el('h1', null, 'Nothing needs you.'),
    el('p', null, 'When DSH needs approval, it will show up here — full command, full question, answer on your phone.')))
}

async function pair() {
  state.pairError = ''
  let value = state.pairText.trim()
  const match = /[?&]token=([^&\s]+)/.exec(value)
  if (match !== null) value = decodeURIComponent(match[1])
  if (value.length === 0) {
    state.pairError = 'Open the pairing link from your Mac on this iPhone first.'
    render()
    return
  }
  try {
    const { response, data } = await api('/api/pair', {
      method: 'POST',
      body: JSON.stringify({ token: value }),
    })
    if (!response.ok) {
      state.pairError = data?.error === 'too-many-attempts'
        ? 'Too many attempts. Wait a few minutes.'
        : 'That pairing token did not match.'
      render()
      return
    }
    state.pairText = ''
    state.pairing = false
    state.pairError = ''
    await load()
    if (!state.pairing) connect()
  } catch {
    state.pairError = 'Could not reach your Mac.'
    render()
  }
}

function renderPairing() {
  const hasToken = state.pairText.trim().length > 0
  main.replaceChildren(el('div', { class: 'pair' },
    el('h1', null, 'Connect this iPhone'),
    el('p', null, 'Approve or deny DSH actions from your phone. You decide each one; cue9 never starts a new action from this screen.'),
    hasToken
      ? el('button', { class: 'btn primary', type: 'button', onclick: () => void pair() }, 'Connect')
      : el('p', { class: 'pair-hint' }, 'Open the pairing link from your Mac on this iPhone.'),
    state.pairError ? el('div', { class: 'error' }, state.pairError) : null,
    el('div', { class: 'howto' },
      el('h2', null, 'Add cue9 to your Home Screen'),
      el('ol', null,
        el('li', null, 'Tap the Share button in Safari.'),
        el('li', null, 'Choose Add to Home Screen.'),
        el('li', null, 'Open cue9 from the Home Screen.'),
        el('li', null, 'Tap Enable alerts.'))),
    el('button', { class: 'link', type: 'button', onclick: () => void load() }, 'I already connected')))
}

function renderApproval(request) {
  const code = codeOf(request)
  const title = request.title ?? 'Approval needed'
  const detail = request.displayReason ?? request.reason
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(code)
      toast('Code copied.')
    } catch {
      toast('Copy is not available here.')
    }
  }

  return el('div', { class: 'card' },
    el('div', { class: 'card-body' },
      el('div', { class: 'kicker' }, `Approval · ${request.toolName ?? 'tool'}`),
      el('h2', { class: 'title' }, title),
      el('div', { class: 'meta' }, metaOf(request)),
      detail ? el('p', { class: 'reason' }, detail) : null,
      code ? el('pre', { class: 'code' }, code) : null,
      code ? el('div', { class: 'codebar' },
        el('button', { class: 'link', type: 'button', onclick: copy }, 'Copy code')) : null,
      state.error ? el('div', { class: 'error' }, state.error) : null),
    el('div', { class: 'actions' },
      el('button', {
        class: 'btn',
        type: 'button',
        disabled: state.busy,
        onclick: () => void answer(request, { outcome: 'rejected' }),
      }, 'Deny'),
      el('button', {
        class: 'btn primary',
        type: 'button',
        disabled: state.busy,
        onclick: () => void answer(request, { outcome: 'allowed-once' }),
      }, state.busy ? 'Sending…' : 'Allow once')))
}

function renderQuestion(request) {
  ensureDraft(request)
  const blocks = (request.questions ?? []).map((question, index) => {
    const value = state.draft?.[question.id] ?? { selected: [], custom: '' }
    const intent = question.intent
    return el('div', { class: 'q', dataset: { qid: question.id } },
      el('div', { class: 'qhead' },
        el('span', { class: 'qnum' }, `${index + 1} / ${request.questions.length}`),
        el('div', null,
          question.header ? el('div', { class: 'qh' }, question.header) : null,
          el('h3', null, question.question))),
      question.detail ? el('div', { class: 'qdetail' }, question.detail) : null,
      (question.options ?? []).map(option => {
        const selected = value.selected.includes(option.label)
        const approve = intent?.kind === 'plan-review' && intent.approve === option.label
        return el('label', {
          class: `opt${selected || (approve && value.selected.length === 0) ? ' on' : ''}`,
          dataset: { qid: question.id, label: option.label },
        },
        el('input', {
          type: question.multiSelect === true ? 'checkbox' : 'radio',
          name: `q-${request.reqId}-${question.id}`,
          checked: selected,
          onchange: () => {
            const current = state.draft[question.id]
            if (question.multiSelect === true) {
              current.selected = current.selected.includes(option.label)
                ? current.selected.filter(item => item !== option.label)
                : [...current.selected, option.label]
            } else {
              current.selected = [option.label]
              current.custom = ''
            }
            syncQuestion(question.id)
          },
        }),
        el('div', null,
          el('b', null, option.label),
          option.description ? el('span', null, option.description) : null))
      }),
      el('input', {
        class: 'custom',
        type: 'text',
        placeholder: (question.options ?? []).length > 0 ? 'Or type your own answer' : 'Type your answer',
        value: value.custom,
        dataset: { custom: question.id },
        oninput: event => {
          const current = state.draft[question.id]
          current.custom = event.target.value
          if (question.multiSelect !== true) current.selected = []
          syncQuestion(question.id)
        },
      }),
      el('button', {
        class: 'skip',
        type: 'button',
        onclick: () => {
          state.draft[question.id] = { selected: [], custom: '' }
          syncQuestion(question.id)
        },
      }, 'Skip this question'))
  })

  const submit = async () => {
    ensureDraft(request)
    const answers = (request.questions ?? []).map(question => {
      const value = state.draft?.[question.id] ?? { selected: [], custom: '' }
      return {
        id: question.id,
        selected: value.selected,
        ...(value.custom.trim().length > 0 ? { custom: value.custom.trim() } : {}),
      }
    })
    await answer(request, { answers })
  }

  return el('div', { class: 'card' },
    el('div', { class: 'card-body' },
      el('div', { class: 'kicker' }, 'Question'),
      el('h2', { class: 'title' }, request.title ?? 'Question from cue9'),
      el('div', { class: 'meta' }, [
        request.questions?.length > 1 ? `${request.questions.length} questions` : 'One question',
        metaOf(request),
      ].filter(value => typeof value === 'string' && value.length > 0).join(' · ')),
      ...blocks,
      state.error ? el('div', { class: 'error' }, state.error) : null),
    el('div', { class: 'actions' },
      el('button', { class: 'btn primary', type: 'button', disabled: state.busy, onclick: submit }, state.busy ? 'Sending…' : 'Send answer')))
}

function render() {
  setStatus()
  renderAlerts()
  syncAppBadge()
  if (state.pairing) {
    renderPairing()
    return
  }
  if (state.requests.length === 0) {
    renderEmpty()
    return
  }

  const active = activeRequest()
  ensureDraft(active)
  const chips = state.requests.length > 1
    ? el('div', { class: 'chips' }, state.requests.map((request, index) =>
      el('button', {
        class: `chip${request.reqId === active.reqId ? ' on' : ''}`,
        type: 'button',
        onclick: () => select(request.reqId),
      }, `${index + 1}. ${request.kind === 'approval' ? (request.toolName ?? 'approval') : 'question'}`)))
    : null

  main.replaceChildren(
    chips,
    active.kind === 'approval' ? renderApproval(active) : renderQuestion(active))
}

/**
 * A pairing link only fills the input. The user must tap Pair so a one-time
 * token cannot be consumed by a chat/link preview or an automatic reload.
 */
function takePairingTokenFromUrl() {
  try {
    const url = new URL(location.href)
    const token = url.searchParams.get('token')
    if (typeof token !== 'string' || token.length === 0) return false
    state.pairText = token
    state.pairing = true
    url.searchParams.delete('token')
    const next = `${url.pathname}${url.search}${url.hash}`
    if (typeof history.replaceState === 'function') history.replaceState(null, '', next)
    return true
  } catch {
    return false
  }
}

async function load() {
  try {
    const { response, data } = await api('/api/pending')
    if (response.status === 401) {
      disconnect()
      state.pairing = true
      state.busy = false
      state.error = ''
      setStatus()
      render()
      return
    }
    if (!response.ok) return
    state.pairing = false
    state.error = ''
    state.requests = Array.isArray(data?.requests) ? data.requests : []
    if (!state.requests.some(request => request.reqId === state.activeId)) {
      state.activeId = state.requests[0]?.reqId ?? null
    }
    const hashMatch = /^#\/r\/(.+)$/.exec(location.hash)
    if (hashMatch) {
      const wanted = decodeURIComponent(hashMatch[1])
      if (state.requests.some(request => request.reqId === wanted)) state.activeId = wanted
    }
    ensureDraft(activeRequest())
    render()
    for (const request of state.requests) void ack(request)
    void refreshAlerts()
  } catch {
    setStatus()
  }
}

function disconnect() {
  if (source !== undefined) {
    source.close()
    source = undefined
  }
  state.connected = false
  setStatus()
}

async function checkSession() {
  if (state.pairing) return
  const now = Date.now()
  if (now - lastAuthCheck < 5000) return
  lastAuthCheck = now
  try {
    const response = await fetch('/api/pending', { credentials: 'same-origin' })
    if (response.status === 401) {
      disconnect()
      if (!state.pairing) {
        state.pairing = true
        state.busy = false
        state.error = ''
        setStatus()
        render()
      }
    }
  } catch { /* network; EventSource keeps its own backoff */ }
}

function connect() {
  if (source !== undefined) source.close()
  source = new EventSource('/api/events')
  source.onopen = () => {
    state.connected = true
    setStatus()
    void load()
  }
  source.onerror = () => {
    state.connected = false
    setStatus()
    void checkSession()
  }
  source.addEventListener('snapshot', event => {
    let data
    try { data = JSON.parse(event.data) } catch { return }
    state.requests = Array.isArray(data?.requests) ? data.requests : []
    if (!state.requests.some(request => request.reqId === state.activeId)) {
      state.activeId = state.requests[0]?.reqId ?? null
    }
    ensureDraft(activeRequest())
    render()
    for (const request of state.requests) void ack(request)
  })
  source.addEventListener('request', event => {
    let request
    try { request = JSON.parse(event.data) } catch { return }
    if (!state.requests.some(item => item.reqId === request.reqId)) {
      state.requests = [...state.requests, request]
    }
    if (state.activeId === null) {
      state.activeId = request.reqId
      ensureDraft(request)
    }
    void ack(request)
    render()
  })
  source.addEventListener('resolved', event => {
    let data
    try { data = JSON.parse(event.data) } catch { return }
    removeRequest(data.reqId)
    if (data.source === 'panel') toast('Answered on your Mac.')
    else if (data.source === 'phone') toast('Sent. DSH is continuing.')
    else if (data.source === 'abort') toast('That request was cancelled.')
  })
  source.addEventListener('handoff', event => {
    let data
    try { data = JSON.parse(event.data) } catch { return }
    removeRequest(data.reqId)
  })
}

function isStandalone() {
  return window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true
}

function urlBase64ToUint8Array(value) {
  const padding = '='.repeat((4 - (value.length % 4)) % 4)
  const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(base64)
  const out = new Uint8Array(raw.length)
  for (let index = 0; index < raw.length; index += 1) out[index] = raw.charCodeAt(index)
  return out
}

function syncAppBadge(count = state.pairing ? 0 : state.requests.length) {
  try {
    if (count > 0 && typeof navigator.setAppBadge === 'function') {
      Promise.resolve(navigator.setAppBadge(count)).catch(() => {})
    } else if (count === 0 && typeof navigator.clearAppBadge === 'function') {
      Promise.resolve(navigator.clearAppBadge()).catch(() => {})
    }
  } catch { /* badges are best effort */ }
}

function alertCard({ icon, title, body, note, actionLabel, action, muted = false }) {
  return el('div', { class: `alert-card${muted ? ' muted' : ''}` },
    el('div', { class: 'alert-icon', 'aria-hidden': 'true' }, icon),
    el('div', { class: 'alert-copy' },
      el('strong', null, title),
      el('p', null, body),
      note ? el('small', { class: 'alert-note' }, note) : null),
    actionLabel
      ? el('div', { class: 'alert-action' },
        el('button', {
          class: 'btn primary',
          type: 'button',
          disabled: alertState.busy,
          onclick: action,
        }, actionLabel))
      : null)
}

function renderAlerts() {
  const header = document.getElementById('alerts')
  const banner = document.getElementById('alertsBanner')
  if (header === null || banner === null) return

  const on = !state.pairing && alertState.status === 'on'
  header.hidden = !on
  header.disabled = alertState.busy
  header.textContent = alertState.busy ? 'Alerts…' : 'Alerts on'
  header.classList.toggle('on', on)
  header.setAttribute('aria-label', on ? 'Turn off alerts' : 'Alerts')
  header.setAttribute('aria-pressed', String(on))
  header.title = on ? 'Alerts are on. Focus or Do Not Disturb can silence notifications.' : ''
  header.onclick = on
    ? () => { if (!alertState.busy) void disableAlerts() }
    : null

  if (state.pairing || alertState.status === 'checking' || on) {
    banner.hidden = true
    banner.replaceChildren()
    return
  }

  let card
  if (alertState.status === 'install') {
    card = alertCard({
      icon: '＋',
      title: 'Add cue9 to your Home Screen',
      body: alertState.permission === 'denied'
        ? 'Alerts need the installed app. Tap Share in Safari → Add to Home Screen. If notifications were denied before, allow cue9 in Settings → Notifications.'
        : 'Alerts need the installed app. Tap Share in Safari → Add to Home Screen, open cue9 from the Home Screen, then tap Enable alerts.',
      note: 'Focus or Do Not Disturb can also silence alerts. Safari may appear as a second cue9 in Focus; the Home Screen app is the one that delivers.',
      muted: true,
    })
  } else if (alertState.status === 'denied') {
    card = alertCard({
      icon: '🔕',
      title: 'Notifications are off',
      body: 'Enable them in iPhone Settings → Notifications → cue9, then come back.',
      note: 'Focus or Do Not Disturb can also silence alerts.',
      actionLabel: 'Check again',
      action: () => void refreshAlerts(),
      muted: true,
    })
  } else if (alertState.status === 'server-off') {
    card = alertCard({
      icon: '⚠',
      title: "Alerts aren't ready on your Mac",
      body: 'Finish the phone setup on your Mac, then check again.',
      actionLabel: 'Check again',
      action: () => void refreshAlerts(),
      muted: true,
    })
  } else if (alertState.status === 'unsupported') {
    card = alertCard({
      icon: '⚠',
      title: "Alerts aren't available here",
      body: 'Open cue9 from the Home Screen in Safari to enable notifications.',
      muted: true,
    })
  } else if (alertState.status === 'error') {
    card = alertCard({
      icon: '⚠',
      title: 'Could not check alerts',
      body: alertState.error || 'Tap again in a moment.',
      actionLabel: 'Try again',
      action: () => void refreshAlerts(),
      muted: true,
    })
  } else {
    const error = alertState.error ? ` ${alertState.error}` : ''
    card = alertCard({
      icon: '🔔',
      title: "Don't miss an approval",
      body: `Get a notification on this iPhone when cue9 needs an answer.${error}`,
      note: 'If alerts seem silent, check Focus or Do Not Disturb.',
      actionLabel: alertState.busy ? 'Enabling…' : alertState.error ? 'Try again' : 'Enable alerts',
      action: () => void enableAlerts(),
    })
  }

  banner.replaceChildren(card)
  banner.hidden = false
}

async function refreshAlerts() {
  if (alertState.probing || alertState.busy) return
  const revision = alertState.revision
  alertState.probing = true
  try {
    alertState.permission = typeof Notification !== 'undefined' ? Notification.permission : 'unsupported'

    if (!isStandalone()) {
      alertState.status = 'install'
      alertState.error = ''
      renderAlerts()
      return
    }
    if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
      alertState.status = 'unsupported'
      alertState.error = ''
      renderAlerts()
      return
    }
    if (Notification.permission === 'denied') {
      alertState.status = 'denied'
      alertState.error = ''
      renderAlerts()
      return
    }
    if (alertState.disabled) {
      alertState.status = 'off'
      renderAlerts()
      return
    }

    let key = alertState.key
    if (typeof key !== 'string' || key.length === 0) {
      let response
      let data
      try {
        ({ response, data } = await api('/api/push/key'))
      } catch {
        if (revision === alertState.revision) {
          alertState.status = 'error'
          alertState.error = 'Could not reach your Mac.'
          renderAlerts()
        }
        return
      }
      if (response.status === 401) return
      if (!response.ok || typeof data?.key !== 'string' || data.key.length === 0) {
        alertState.status = 'server-off'
        alertState.error = ''
        renderAlerts()
        return
      }
      key = data.key
      alertState.key = key
    }
    if (revision !== alertState.revision) return

    let registration
    try {
      registration = await navigator.serviceWorker.ready
    } catch {
      if (revision === alertState.revision) {
        alertState.status = 'error'
        alertState.error = 'Alerts are unavailable in this browser.'
        renderAlerts()
      }
      return
    }
    if (revision !== alertState.revision) return
    alertState.registration = registration

    const existing = await registration.pushManager.getSubscription().catch(() => null)
    if (revision !== alertState.revision) return
    alertState.subscription = existing

    if (existing !== null && Notification.permission === 'granted') {
      const { response } = await api('/api/push/subscribe', {
        method: 'POST',
        body: JSON.stringify({ subscription: existing.toJSON() }),
      })
      if (revision !== alertState.revision) return
      if (response.status === 401) return
      if (!response.ok) {
        alertState.status = 'off'
        alertState.error = 'Could not sync alerts with your Mac.'
        renderAlerts()
        return
      }
      alertState.status = 'on'
      alertState.error = ''
      renderAlerts()
      return
    }

    alertState.status = 'off'
    alertState.error = ''
    renderAlerts()
  } catch {
    if (revision === alertState.revision && !alertState.busy) {
      alertState.status = 'error'
      alertState.error = 'Could not check alerts. Try again.'
      renderAlerts()
    }
  } finally {
    alertState.probing = false
  }
}

async function enableAlerts() {
  if (alertState.busy) return
  alertState.revision += 1
  alertState.disabled = false
  alertState.permission = typeof Notification !== 'undefined' ? Notification.permission : 'unsupported'

  if (!isStandalone()) {
    alertState.status = 'install'
    alertState.error = ''
    renderAlerts()
    return
  }
  if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
    alertState.status = 'unsupported'
    alertState.error = ''
    renderAlerts()
    return
  }
  if (Notification.permission === 'denied') {
    alertState.status = 'denied'
    alertState.error = ''
    renderAlerts()
    return
  }

  alertState.busy = true
  alertState.error = ''
  renderAlerts()
  try {
    let permission = Notification.permission
    if (permission !== 'granted') permission = await Notification.requestPermission()
    alertState.permission = permission
    if (permission !== 'granted') {
      alertState.status = permission === 'denied' ? 'denied' : 'off'
      alertState.error = permission === 'denied'
        ? 'Allow cue9 in iPhone Settings → Notifications, then check again.'
        : 'Notifications were not enabled.'
      toast(alertState.error)
      return
    }

    let key = alertState.key
    if (typeof key !== 'string' || key.length === 0) {
      const { response, data } = await api('/api/push/key')
      if (response.status === 401) return
      if (!response.ok || typeof data?.key !== 'string' || data.key.length === 0) {
        alertState.status = 'server-off'
        alertState.error = ''
        return
      }
      key = data.key
      alertState.key = key
    }

    const registration = await navigator.serviceWorker.ready
    alertState.registration = registration
    let subscription = await registration.pushManager.getSubscription()
    if (subscription === null) {
      subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(key),
      })
    }
    alertState.subscription = subscription

    const { response } = await api('/api/push/subscribe', {
      method: 'POST',
      body: JSON.stringify({ subscription: subscription.toJSON() }),
    })
    if (response.status === 401) return
    if (!response.ok) {
      alertState.status = 'off'
      alertState.error = 'Your Mac did not accept the alert subscription. Try again.'
      toast(alertState.error)
      return
    }

    alertState.status = 'on'
    alertState.error = ''
    toast('Alerts enabled.')
  } catch (error) {
    const denied = error?.name === 'NotAllowedError' || Notification.permission === 'denied'
    alertState.status = denied ? 'denied' : 'off'
    alertState.error = denied
      ? 'Allow cue9 in iPhone Settings → Notifications, then check again.'
      : 'Could not enable alerts. Try again.'
    toast(alertState.error)
  } finally {
    alertState.busy = false
    renderAlerts()
  }
}

async function disableAlerts() {
  if (alertState.busy) return
  alertState.revision += 1
  alertState.disabled = true
  alertState.busy = true
  alertState.error = ''
  renderAlerts()
  try {
    let registration = alertState.registration
    if (registration === null) registration = await navigator.serviceWorker.ready
    const subscription = await registration.pushManager.getSubscription()
    if (subscription !== null) await subscription.unsubscribe()

    const { response } = await api('/api/push/unsubscribe', {
      method: 'POST',
      body: JSON.stringify({}),
    })
    if (response.status === 401) return
    if (!response.ok) throw new Error('unsubscribe failed')

    alertState.subscription = null
    alertState.status = 'off'
    alertState.error = ''
    toast('Alerts off.')
  } catch {
    alertState.disabled = false
    alertState.status = 'on'
    alertState.error = ''
    toast('Could not turn off alerts. Try again.')
  } finally {
    alertState.busy = false
    renderAlerts()
  }
}

window.addEventListener('hashchange', () => {
  const match = /^#\/r\/(.+)$/.exec(location.hash)
  if (!match) return
  const wanted = decodeURIComponent(match[1])
  if (state.requests.some(request => request.reqId === wanted)) select(wanted)
})

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', event => {
    const data = event.data
    if (data === null || typeof data !== 'object' || data.type !== 'cue9-push') return
    toast('Push received — cue9 has a new request.', 6000)
    syncAppBadge(Math.max(1, state.requests.length))
    void load()
  })
  navigator.serviceWorker.register('/sw.js').catch(() => {})
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) return
  if (!state.pairing) void refreshAlerts()
})

if (takePairingTokenFromUrl()) render()
void load().then(() => {
  if (!state.pairing) connect()
})
