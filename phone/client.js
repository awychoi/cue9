/** cue9 phone bridge: the laptop panel and its shared rendering. */
window.__ModuleLoader__.load({
  id: 'dsh-cue9-phone',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const API = '/plugins/cue9-phone'
    const HEADERS = { 'content-type': 'application/json', 'x-cue9-phone': '1' }

    const CSS = `
.c9p-panel{position:fixed;right:22px;bottom:22px;z-index:2147483000;width:min(440px,calc(100vw - 44px));
  max-height:min(78vh,720px);display:flex;flex-direction:column;pointer-events:auto;
  background:#0b0b0c;color:#f5f1ea;border:1px solid #2b2b2e;border-radius:18px;
  box-shadow:0 18px 60px rgba(0,0,0,.55),0 0 0 1px rgba(255,255,255,.03) inset;
  font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;
  overflow:hidden;letter-spacing:-.01em}
.c9p-head{display:flex;align-items:center;gap:9px;padding:13px 15px 10px;border-bottom:1px solid #232326}
.c9p-mark{width:22px;height:22px;border-radius:7px;background:#000;display:grid;place-items:center;flex:0 0 auto}
.c9p-mark svg{width:16px;height:16px;display:block}
.c9p-word{font-weight:650;font-size:13px;letter-spacing:.01em}
.c9p-sub{color:#8f8b85;font-size:11px;margin-left:auto;white-space:nowrap}
.c9p-dot{width:6px;height:6px;border-radius:50%;background:#FF6A00;box-shadow:0 0 8px rgba(255,106,0,.7);display:inline-block;margin-right:5px;vertical-align:1px}
.c9p-body{padding:14px 15px 4px;overflow:auto}
.c9p-kicker{font-size:10.5px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:#FF6A00;margin-bottom:6px}
.c9p-title{font-size:18px;font-weight:650;line-height:1.2;margin:0 0 4px;letter-spacing:-.02em}
.c9p-meta{color:#8f8b85;font-size:11.5px;margin:0 0 11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.c9p-reason{color:#cfc8bf;font-size:13px;margin:0 0 10px}
.c9p-code{margin:0 0 10px;padding:11px 12px;background:#151517;border:1px solid #26262a;border-radius:11px;
  color:#f7e8d8;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-word;
  max-height:170px;overflow:auto}
.c9p-codebar{display:flex;align-items:center;gap:8px;margin:-2px 0 10px}
.c9p-link{background:none;border:0;padding:0;color:#8f8b85;font-size:11.5px;cursor:pointer;text-decoration:underline;text-underline-offset:2px}
.c9p-link:hover{color:#f5f1ea}
.c9p-actions{display:flex;gap:8px;align-items:center;padding:10px 15px 13px;border-top:1px solid #232326;background:#0b0b0c}
.c9p-btn{appearance:none;border:1px solid #333338;background:#171719;color:#f5f1ea;border-radius:11px;
  padding:9px 13px;font:600 12.5px/1 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;cursor:pointer;
  min-height:36px;transition:background .15s,border-color .15s,transform .05s}
.c9p-btn:hover{background:#202024;border-color:#45454b}
.c9p-btn:active{transform:translateY(1px)}
.c9p-btn:disabled{opacity:.5;cursor:default}
.c9p-btn.primary{background:#FF6A00;border-color:#FF6A00;color:#140a02}
.c9p-btn.primary:hover{background:#ff7d1f;border-color:#ff7d1f}
.c9p-btn.ghost{margin-left:auto;background:none;border-color:transparent;color:#8f8b85;font-weight:500}
.c9p-btn.ghost:hover{color:#f5f1ea;background:#171719}
.c9p-chips{display:flex;gap:6px;padding:9px 15px 0;flex-wrap:wrap}
.c9p-chip{border:1px solid #2c2c30;background:#121214;color:#a8a29a;border-radius:999px;padding:4px 9px;
  font-size:11px;cursor:pointer;max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.c9p-chip.on{border-color:#FF6A00;color:#ffd3b3;background:#1d120a}
.c9p-q{padding:12px 0 4px;border-top:1px solid #232326}
.c9p-q:first-child{border-top:0;padding-top:0}
.c9p-qhead{display:flex;gap:7px;align-items:baseline;margin-bottom:5px}
.c9p-qnum{color:#FF6A00;font-size:10.5px;font-weight:700;letter-spacing:.06em}
.c9p-qtitle{font-size:14px;font-weight:620;line-height:1.35;margin:0}
.c9p-qdetail{color:#a8a29a;font-size:12.5px;white-space:pre-wrap;margin:6px 0 8px;max-height:160px;overflow:auto}
.c9p-opt{display:flex;gap:9px;align-items:flex-start;border:1px solid #2b2b2f;border-radius:11px;padding:10px 11px;
  margin:6px 0;cursor:pointer;background:#121214}
.c9p-opt:hover{border-color:#414147}
.c9p-opt.on{border-color:#FF6A00;background:#1d120a}
.c9p-opt input{margin:2px 0 0;accent-color:#FF6A00;width:15px;height:15px;flex:0 0 auto}
.c9p-opt b{display:block;font-size:13px;font-weight:600}
.c9p-opt span{display:block;color:#8f8b85;font-size:11.5px;margin-top:2px}
.c9p-custom{width:100%;box-sizing:border-box;margin:7px 0 0;padding:10px 11px;border-radius:11px;
  border:1px solid #2b2b2f;background:#121214;color:#f5f1ea;font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;resize:vertical}
.c9p-custom:focus{outline:none;border-color:#FF6A00}
.c9p-skip{background:none;border:0;color:#8f8b85;font-size:11px;text-decoration:underline;cursor:pointer;padding:2px 0;margin-top:6px}
.c9p-error{color:#ff9d7a;font-size:12px;padding:0 15px 6px}
.c9p-empty{padding:24px 18px;color:#8f8b85;font-size:13px;text-align:center}
.c9p-toast{position:fixed;right:24px;bottom:24px;z-index:2147483001;background:#171719;color:#f5f1ea;
  border:1px solid #333338;border-radius:12px;padding:10px 13px;font:500 12.5px -apple-system,BlinkMacSystemFont,sans-serif;
  box-shadow:0 10px 30px rgba(0,0,0,.4);pointer-events:none}
@media(max-width:700px){.c9p-panel{right:0;bottom:0;width:100%;max-height:82vh;border-radius:18px 18px 0 0}}
`

    const MARK = h('svg', { viewBox: '0 0 1024 1024', 'aria-hidden': true },
      h('rect', { width: 1024, height: 1024, rx: 228, fill: '#000' }),
      h('g', { transform: 'translate(132 132) scale(1.484375)' },
        h('g', { transform: 'rotate(-32 256 256)' },
          h('path', { d: 'M 398.472 345.026 A 168 168 0 1 1 398.472 166.974', fill: 'none', stroke: '#fff', strokeWidth: 62, strokeLinecap: 'round' }),
          h('ellipse', { cx: 214, cy: 236, rx: 25, ry: 38, fill: '#fff' }),
          h('ellipse', { cx: 306, cy: 224, rx: 28, ry: 42, fill: '#fff' }))),
      h('circle', { cx: 773.391, cy: 773.391, r: 34, fill: '#FF6A00' }))

    async function post(path, body) {
      const response = await fetch(`${API}${path}`, {
        method: 'POST',
        headers: HEADERS,
        body: JSON.stringify(body),
      })
      let data = {}
      try { data = await response.json() } catch { /* empty body */ }
      return { ok: response.ok, status: response.status, data }
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

    function initialDraft(request) {
      const draft = {}
      for (const question of request.questions ?? []) {
        draft[question.id] = { selected: [], custom: '' }
      }
      return draft
    }

    function QuestionForm({ request, onAnswer, busy }) {
      const [draft, setDraft] = React.useState(() => initialDraft(request))
      const [error, setError] = React.useState('')

      React.useEffect(() => { setDraft(initialDraft(request)) }, [request.reqId])

      function setOne(id, next) {
        setDraft(current => ({ ...current, [id]: { ...current[id], ...next } }))
      }

      function choose(question, label) {
        const current = draft[question.id] ?? { selected: [], custom: '' }
        if (question.multiSelect === true) {
          const selected = current.selected.includes(label)
            ? current.selected.filter(item => item !== label)
            : [...current.selected, label]
          setOne(question.id, { selected })
        } else {
          setOne(question.id, { selected: [label], custom: '' })
        }
      }

      function custom(question, value) {
        if (question.multiSelect === true) setOne(question.id, { custom: value })
        else setOne(question.id, { custom: value, selected: value.length > 0 ? [] : draft[question.id]?.selected ?? [] })
      }

      function skip(question) {
        setOne(question.id, { selected: [], custom: '' })
      }

      async function submit() {
        setError('')
        const answers = (request.questions ?? []).map(question => {
          const value = draft[question.id] ?? { selected: [], custom: '' }
          return {
            id: question.id,
            selected: value.selected,
            ...(value.custom.trim().length > 0 ? { custom: value.custom.trim() } : {}),
          }
        })
        const result = await onAnswer({ answers })
        if (!result.ok) setError(result.data?.error === 'invalid-answer' ? 'That answer is not valid.' : 'Could not send. Try again.')
      }

      return h('div', { className: 'c9p-body' },
        h('div', { className: 'c9p-kicker' }, 'Question'),
        h('h2', { className: 'c9p-title' }, request.title ?? 'Question from cue9'),
        (request.questions ?? []).length > 1
          ? h('div', { className: 'c9p-meta' }, `${request.questions.length} questions`)
          : null,
        (request.questions ?? []).map((question, index) => {
          const value = draft[question.id] ?? { selected: [], custom: '' }
          const intent = question.intent
          return h('div', { className: 'c9p-q', key: question.id },
            h('div', { className: 'c9p-qhead' },
              h('span', { className: 'c9p-qnum' }, `${index + 1} / ${request.questions.length}`),
              h('div', null,
                question.header ? h('div', { className: 'c9p-kicker' }, question.header) : null,
                h('h3', { className: 'c9p-qtitle' }, question.question))),
            question.detail ? h('div', { className: 'c9p-qdetail' }, question.detail) : null,
            (question.options ?? []).map(option => {
              const selected = value.selected.includes(option.label)
              const approve = intent?.kind === 'plan-review' && intent.approve === option.label
              return h('label', {
                key: option.label,
                className: `c9p-opt${selected || (approve && value.selected.length === 0) ? ' on' : ''}`,
              },
              h('input', {
                type: question.multiSelect === true ? 'checkbox' : 'radio',
                name: `cue9-${request.reqId}-${question.id}`,
                checked: selected,
                onChange: () => choose(question, option.label),
              }),
              h('div', null,
                h('b', null, option.label),
                option.description ? h('span', null, option.description) : null))
            }),
            h('input', {
              className: 'c9p-custom',
              type: 'text',
              placeholder: (question.options ?? []).length > 0 ? 'Or type your own answer' : 'Type your answer',
              value: value.custom,
              onChange: event => custom(question, event.target.value),
            }),
            h('button', { type: 'button', className: 'c9p-skip', onClick: () => skip(question) }, 'Skip this question'))
        }),
        error ? h('div', { className: 'c9p-error' }, error) : null,
        h('div', { className: 'c9p-actions' },
          h('button', { className: 'c9p-btn primary', type: 'button', disabled: busy, onClick: submit }, busy ? 'Sending…' : 'Send answer')))
    }

    function ApprovalCard({ request, onAnswer, busy }) {
      const code = codeOf(request)
      const detail = request.displayReason ?? request.reason
      const rawDetail = request.reason && request.displayReason && request.reason !== request.displayReason
        ? request.reason
        : null
      const [copied, setCopied] = React.useState(false)
      async function copy() {
        try {
          await navigator.clipboard.writeText(code)
          setCopied(true)
          setTimeout(() => setCopied(false), 1400)
        } catch { /* clipboard unavailable */ }
      }
      return h('div', null,
        h('div', { className: 'c9p-body' },
          h('div', { className: 'c9p-kicker' }, 'Approval · ' + (request.toolName ?? 'tool')),
          h('h2', { className: 'c9p-title' }, request.title ?? 'Approval needed'),
          h('div', { className: 'c9p-meta' },
            request.cwd ? `${request.cwd}` : request.sessionId ?? ''),
          detail ? h('p', { className: 'c9p-reason' }, detail) : null,
          rawDetail ? h('p', { className: 'c9p-reason' }, rawDetail) : null,
          code ? h('pre', { className: 'c9p-code' }, code) : null,
          code ? h('div', { className: 'c9p-codebar' },
            h('button', { type: 'button', className: 'c9p-link', onClick: copy }, copied ? 'Copied' : 'Copy code')) : null),
        h('div', { className: 'c9p-actions' },
          h('button', { className: 'c9p-btn', type: 'button', disabled: busy, onClick: () => onAnswer({ outcome: 'rejected' }) }, 'Deny'),
          h('button', { className: 'c9p-btn primary', type: 'button', disabled: busy, onClick: () => onAnswer({ outcome: 'allowed-once' }) }, 'Allow once')))
    }

    function Panel() {
      const [requests, setRequests] = React.useState([])
      const [activeId, setActiveId] = React.useState(null)
      const [busy, setBusy] = React.useState(false)
      const [notice, setNotice] = React.useState(null)
      const [connected, setConnected] = React.useState(false)
      const [expired, setExpired] = React.useState(false)
      const streamRef = React.useRef(null)
      const expiredRef = React.useRef(false)
      const authCheckAt = React.useRef(0)

      function failSession() {
        if (expiredRef.current) return
        expiredRef.current = true
        setExpired(true)
        streamRef.current?.close()
        streamRef.current = null
      }

      function dropStale(reqId, status) {
        setRequests(current => current.filter(item => item.reqId !== reqId))
        setNotice(status === 404 ? 'Already handled.' : 'This request changed; refresh.')
        setTimeout(() => setNotice(null), 2600)
      }

      async function ack(request) {
        if (expiredRef.current || request === undefined) return
        try {
          const result = await post('/ack', claimOf(request))
          if (result.status === 401) {
            failSession()
            return
          }
          if (result.status === 404 || result.status === 409) {
            dropStale(request.reqId, result.status)
          }
        } catch { /* best effort */ }
      }

      React.useEffect(() => {
        if (expiredRef.current) return
        let alive = true

        async function checkAuth() {
          if (!alive || expiredRef.current) return
          const now = Date.now()
          if (now - authCheckAt.current < 5000) return
          authCheckAt.current = now
          try {
            const response = await fetch(`${API}/pending`)
            if (response.status === 401) failSession()
          } catch { /* network hiccup; EventSource keeps its own backoff */ }
        }

        const load = async () => {
          try {
            const response = await fetch(`${API}/pending`)
            if (!alive) return
            if (response.status === 401) {
              failSession()
              return
            }
            if (!response.ok) return
            const data = await response.json()
            if (!alive || expiredRef.current) return
            const next = Array.isArray(data?.requests) ? data.requests : []
            setRequests(next)
            for (const request of next) void ack(request)
          } catch { /* the panel simply waits for SSE */ }
        }

        void load()
        const source = new EventSource(`${API}/events`)
        if (expiredRef.current) {
          source.close()
          return
        }
        streamRef.current = source
        source.onopen = () => {
          if (!alive || expiredRef.current) return
          setConnected(true)
          void load()
        }
        source.onerror = () => {
          if (!alive || expiredRef.current) return
          setConnected(false)
          void checkAuth()
        }
        source.addEventListener('snapshot', event => {
          if (!alive || expiredRef.current) return
          const data = JSON.parse(event.data)
          const next = Array.isArray(data?.requests) ? data.requests : []
          setRequests(next)
          for (const request of next) void ack(request)
        })
        source.addEventListener('request', event => {
          if (!alive || expiredRef.current) return
          const request = JSON.parse(event.data)
          setRequests(current => current.some(item => item.reqId === request.reqId) ? current : [...current, request])
          void ack(request)
        })
        source.addEventListener('resolved', event => {
          if (!alive || expiredRef.current) return
          const data = JSON.parse(event.data)
          setRequests(current => current.filter(item => item.reqId !== data.reqId))
          setNotice(data.source === 'phone' ? 'Answered on your phone.' : data.source === 'panel' ? 'Answered here.' : 'Handled.')
          setTimeout(() => setNotice(null), 2600)
        })
        source.addEventListener('handoff', event => {
          if (!alive || expiredRef.current) return
          const data = JSON.parse(event.data)
          setRequests(current => current.filter(item => item.reqId !== data.reqId))
        })
        return () => {
          alive = false
          source.close()
          if (streamRef.current === source) streamRef.current = null
        }
      }, [])

      React.useEffect(() => {
        if (requests.length === 0) {
          setActiveId(null)
          return
        }
        if (activeId === null || !requests.some(item => item.reqId === activeId)) {
          setActiveId(requests[0].reqId)
        }
      }, [requests, activeId])

      if (expired) {
        return h('div', { className: 'c9p-panel', role: 'dialog', 'aria-label': 'cue9 session expired' },
          h('div', { className: 'c9p-head' },
            h('div', { className: 'c9p-mark' }, MARK),
            h('div', { className: 'c9p-word' }, 'cue9'),
            h('div', { className: 'c9p-sub' }, 'session expired')),
          h('div', { className: 'c9p-empty' }, 'Session expired — reload DSH'),
          h('div', { className: 'c9p-actions' },
            h('button', {
              className: 'c9p-btn primary',
              type: 'button',
              onClick: () => window.location.reload(),
            }, 'Reload DSH')))
      }

      const active = requests.find(item => item.reqId === activeId) ?? requests[0]
      if (active === undefined) {
        return notice ? h('div', { className: 'c9p-toast' }, notice) : null
      }

      async function answer(payload) {
        const request = active
        setBusy(true)
        try {
          const result = await post('/answer', { ...claimOf(request), ...payload })
          setBusy(false)
          if (result.status === 401) {
            failSession()
            return { ok: false, auth: true }
          }
          if (result.status === 404 || result.status === 409) {
            dropStale(request.reqId, result.status)
            return { ok: true, stale: true }
          }
          if (result.ok) {
            setRequests(current => current.filter(item => item.reqId !== request.reqId))
          }
          return result
        } catch {
          setBusy(false)
          setNotice('Could not reach DSH.')
          setTimeout(() => setNotice(null), 2600)
          return { ok: false, network: true }
        }
      }



      return h(React.Fragment, null,
        h('div', { className: 'c9p-panel', role: 'dialog', 'aria-label': 'cue9 approval' },
          h('div', { className: 'c9p-head' },
            h('div', { className: 'c9p-mark' }, MARK),
            h('div', { className: 'c9p-word' }, 'cue9'),
            h('div', { className: 'c9p-sub' },
              h('span', { className: 'c9p-dot', style: { background: connected ? '#FF6A00' : '#6b6660' } }),
              requests.length > 1 ? `${requests.length} need you` : 'needs you')),
          requests.length > 1
            ? h('div', { className: 'c9p-chips' }, requests.map((request, index) =>
              h('button', {
                type: 'button',
                key: request.reqId,
                className: `c9p-chip${request.reqId === active.reqId ? ' on' : ''}`,
                onClick: () => setActiveId(request.reqId),
              }, `${index + 1}. ${request.kind === 'approval' ? request.toolName : 'question'}`)))
            : null,
          active.kind === 'approval'
            ? h(ApprovalCard, { request: active, onAnswer: answer, busy })
            : h(QuestionForm, { request: active, onAnswer: answer, busy })),
        notice ? h('div', { className: 'c9p-toast' }, notice) : null)
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.effect(() => {
          const style = document.createElement('style')
          style.dataset.cue9Phone = 'panel'
          style.textContent = CSS
          document.head.append(style)
          return () => style.remove()
        }, 'cue9-phone: panel styles')
        ctx.slots.inject('shell.overlay', () => ctx.slots.register({
          name: 'shell.overlay',
          id: 'cue9-phone',
          order: 50,
        }, Panel))
      },
    }
  },
})
