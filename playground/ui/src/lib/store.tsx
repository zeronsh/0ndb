import { createContext, startTransition, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { toast } from 'sonner'
import { api, type FilesChangedEvent, type Info, type Message, type Page, type ProviderInfo, type QueueItem, type ServerEvent, type Session, type TextSplice, type Trace, type TurnDelta, type WorktreeInfo } from './api'
import { loadModels, seedCatalogs, SIMULATOR } from './catalog'

export interface FileActivity {
  kind: 'added' | 'modified' | 'removed'
  source: string
  ts: number
  added: number
  removed: number
  lines: number
  bytes: number
  msg_id: string | null
  splices?: TextSplice[]
  to_version?: string
}

export interface PageLoad {
  at: number
  count: number
  elapsed_us: number
  older: boolean
  has_more: boolean
}

export interface LiveTrace extends Trace {
  msg_id: string
  thread_id: string
  parent_id: string | null
  provider: string
  model: string | null
  text: string
}

type Conn = 'connecting' | 'live' | 'offline'

interface Store {
  info: Info | null
  providers: ProviderInfo[]
  sessions: Session[]
  worktrees: WorktreeInfo[]
  activeWorktreeId: string | null
  activeWorktree: WorktreeInfo | null
  activeId: string | null
  active: Session | null
  queue: QueueItem[]
  workspaceTick: number
  v2Tick: number
  fileActivity: Record<string, FileActivity>
  fileFeed: { path: string; act: FileActivity }[]
  conn: Conn
  pageSize: number
  select: (id: string) => void
  selectWorktree: (id: string) => void
  onFilesChanged: (fn: (ev: FilesChangedEvent) => void) => () => void
  refreshSessions: () => Promise<void>
  refreshWorktrees: () => Promise<void>
  refreshInfo: () => Promise<void>
  refreshPage: () => Promise<void>
  applyPage: (page: Page, opts?: { optimistic?: boolean }) => void
  reconcilePage: (page: Page) => void
  loadOlder: () => Promise<void>
  refreshQueue: () => Promise<void>
  createSession: (title?: string, provider?: string, model?: string | null) => Promise<string | null>
  run: <T>(label: string, fn: () => Promise<T>) => Promise<T | undefined>
}

interface ThreadPageState {
  messages: Message[]
  hasMore: boolean
  nextBefore: string | null
  headPage: string | null
  loads: PageLoad[]
  loadingOlder: boolean
  pageLoaded: boolean
  live: Record<string, LiveTrace>
}

const Ctx = createContext<Store | null>(null)
const ThreadPageCtx = createContext<ThreadPageState | null>(null)

export function useStore() {
  const s = useContext(Ctx)
  if (!s) throw new Error('store missing')
  return s
}

export function useThreadPage() {
  const p = useContext(ThreadPageCtx)
  if (!p) throw new Error('thread page store missing')
  return p
}

function emptyLive(d: TurnDelta, key: string): LiveTrace {
  const provider = d.provider === ('mock-fallback' as string) ? 'mock' : d.provider
  return { msg_id: key, thread_id: d.thread_id, parent_id: d.parent_id ?? null, provider, model: d.model || null, text: '', started_ms: d.ts_ms ?? Date.now(), ended_ms: null, reasoning: [], tools: [], steers: [], usage: null, error: null }
}

function closeReasoning(t: LiveTrace, at: number): LiveTrace {
  const last = t.reasoning.at(-1)
  if (!last || last.ended_ms != null) return t
  return { ...t, reasoning: [...t.reasoning.slice(0, -1), { ...last, ended_ms: at }] }
}

function applyDelta(t: LiveTrace, d: TurnDelta): LiveTrace {
  const at = d.ts_ms ?? Date.now()
  switch (d.kind) {
    case 'reasoning_delta': {
      const last = t.reasoning.at(-1)
      const blockId = d.block ?? (last && last.ended_ms == null ? last.id : (last?.id ?? -1) + 1)
      if (last && last.id === blockId) return { ...t, reasoning: [...t.reasoning.slice(0, -1), { ...last, text: last.text + (d.text ?? ''), ended_ms: null }] }
      return { ...t, reasoning: [...t.reasoning.map(r => (r.ended_ms == null ? { ...r, ended_ms: at } : r)), { id: blockId, text: d.text ?? '', started_ms: at, ended_ms: null }] }
    }
    case 'text_delta':
      return { ...closeReasoning(t, at), text: t.text + (d.text ?? '') }
    case 'tool_started':
      return { ...closeReasoning(t, at), tools: [...t.tools, { id: d.tool_id ?? `tool-${t.tools.length}`, name: d.name ?? 'tool', input: d.input ?? '', output: '', is_error: false, started_ms: at, ended_ms: null }] }
    case 'tool_finished': {
      let hit = false
      const tools = t.tools.map(x => {
        if (hit || x.id !== d.tool_id || x.ended_ms != null) return x
        hit = true
        return { ...x, output: d.text ?? '', is_error: !!d.is_error, ended_ms: at }
      })
      return { ...t, tools }
    }
    case 'steer_injected':
    case 'steer_fallback':
      return { ...t, steers: [...t.steers, { mode: d.kind === 'steer_injected' ? 'native' : 'fallback', prompt: d.text ?? '', at_ms: at }] }
    case 'usage':
      return { ...t, usage: { input_tokens: d.input_tokens ?? 0, output_tokens: d.output_tokens ?? 0 } }
    default:
      return t
  }
}

export function StoreProvider({ children }: { children: ReactNode }) {
  const [info, setInfo] = useState<Info | null>(null)
  const [sessions, setSessions] = useState<Session[]>([])
  const [worktrees, setWorktrees] = useState<WorktreeInfo[]>([])
  const [activeWorktreeId, setActiveWorktreeId] = useState<string | null>(null)
  const [activeId, setActiveId] = useState<string | null>(() => {
    try {
      return localStorage.getItem('ondb-active')
    } catch {
      return null
    }
  })
  const [messages, setMessages] = useState<Message[]>([])
  const [hasMore, setHasMore] = useState(false)
  const [nextBefore, setNextBefore] = useState<string | null>(null)
  const [headPage, setHeadPage] = useState<string | null>(null)
  const [loads, setLoads] = useState<PageLoad[]>([])
  const [loadingOlder, setLoadingOlder] = useState(false)
  const [pageLoaded, setPageLoaded] = useState(false)
  const [queue, setQueue] = useState<QueueItem[]>([])
  const [live, setLive] = useState<Record<string, LiveTrace>>({})
  const [workspaceTick, setWorkspaceTick] = useState(0)
  const [v2Tick, setV2Tick] = useState(0)
  const [fileActivity, setFileActivity] = useState<Record<string, FileActivity>>({})
  const [fileFeed, setFileFeed] = useState<{ path: string; act: FileActivity }[]>([])
  const [conn, setConn] = useState<Conn>('connecting')

  const activeRef = useRef(activeId)
  activeRef.current = activeId
  const activeWorktreeRef = useRef(activeWorktreeId)
  activeWorktreeRef.current = activeWorktreeId
  const countRef = useRef(0)
  countRef.current = messages.length
  const headPageRef = useRef(headPage)
  headPageRef.current = headPage
  const pageSize = info?.page_size ?? 4

  const run = useCallback(async <T,>(label: string, fn: () => Promise<T>) => {
    try {
      return await fn()
    } catch (e) {
      toast.error(label, { description: String((e as Error)?.message ?? e) })
      return undefined
    }
  }, [])

  const refreshInfo = useCallback(async () => {
    const i = await api.info().catch(() => null)
    if (i) setInfo(i)
  }, [])

  const refreshWorktrees = useCallback(async () => {
    const r = await api.worktrees().catch(() => null)
    if (!r) return
    setWorktrees(r.worktrees)
    if (!activeWorktreeRef.current || !r.worktrees.some(w => w.id === activeWorktreeRef.current)) {
      const primary = r.worktrees.find(w => w.is_primary) ?? r.worktrees[0] ?? null
      if (primary) setActiveWorktreeId(primary.id)
    }
  }, [])

  const refreshSessions = useCallback(async () => {
    const r = await api.sessions().catch(() => null)
    if (!r) return
    const sorted = [...r.sessions].sort((a, b) => b.updated_ms - a.updated_ms)
    setSessions(sorted)
    if (!activeRef.current || !sorted.some(s => s.thread_id === activeRef.current)) {
      if (sorted[0]) setActiveId(sorted[0].thread_id)
    }
  }, [])

  const inflight = useRef(0)
  const timers = useRef<Record<string, ReturnType<typeof setTimeout>>>({})
  const deferredFilesRef = useRef<FilesChangedEvent[]>([])
  const filesChangedListeners = useRef(new Set<(ev: FilesChangedEvent) => void>())

  const flushDeferredFiles = useCallback(() => {
    clearTimeout(timers.current.deferredFiles)
    const batch = deferredFilesRef.current.splice(0)
    if (!batch.length) return
    clearTimeout(timers.current.workspaceTick)
    const allEntries: { path: string; act: FileActivity }[] = []
    for (const msg of batch) {
      const ts = msg.ts_ms || Date.now()
      for (const c of msg.changes) {
        allEntries.push({
          path: c.path,
          act: {
            kind: c.kind,
            source: msg.source,
            ts,
            added: c.added,
            removed: c.removed,
            lines: c.lines,
            bytes: c.bytes,
            msg_id: msg.msg_id ?? null,
            splices: c.splices,
            to_version: msg.to_version,
          },
        })
      }
    }
    startTransition(() => {
      setFileActivity(prev => {
        const next = { ...prev }
        for (const e of allEntries) next[e.path] = e.act
        return next
      })
      setFileFeed(prev => [...allEntries.reverse(), ...prev].slice(0, 40))
      setWorkspaceTick(x => x + 1)
      for (const msg of batch) {
        for (const fn of filesChangedListeners.current) fn(msg)
      }
    })
  }, [])

  const optimisticBranchRef = useRef(false)

  const applyPage = useCallback((page: Page, opts?: { optimistic?: boolean }) => {
    inflight.current += 1
    clearTimeout(timers.current.page)
    optimisticBranchRef.current = Boolean(opts?.optimistic)
    setMessages(page.messages)
    setHasMore(page.has_more)
    setNextBefore(page.next_before)
    setPageLoaded(true)
    if (!opts?.optimistic) {
      setHeadPage(page.head_page)
      headPageRef.current = page.head_page
      setLoads(l => [...l.slice(-19), { at: Date.now(), count: page.messages.length, elapsed_us: page.elapsed_us, older: false, has_more: page.has_more }])
      setLive(prev => {
        let changed = false
        const next = { ...prev }
        for (const m of page.messages) {
          if (next[m.msg_id] && m.status !== 'running' && m.trace) {
            delete next[m.msg_id]
            changed = true
          }
        }
        return changed ? next : prev
      })
      if (deferredFilesRef.current.length > 0) {
        clearTimeout(timers.current.deferredFiles)
        requestAnimationFrame(() => flushDeferredFiles())
      }
    }
  }, [flushDeferredFiles])

  const reconcilePage = useCallback((page: Page) => {
    inflight.current += 1
    clearTimeout(timers.current.page)
    optimisticBranchRef.current = false
    headPageRef.current = page.head_page
    startTransition(() => {
      setHeadPage(page.head_page)
      setLoads(l => [...l.slice(-19), { at: Date.now(), count: page.messages.length, elapsed_us: page.elapsed_us, older: false, has_more: page.has_more }])
    })
    if (deferredFilesRef.current.length > 0) {
      flushDeferredFiles()
    }
  }, [flushDeferredFiles])

  const refreshPage = useCallback(async () => {
    const tid = activeRef.current
    if (!tid) return
    const ticket = ++inflight.current
    const limit = Math.max(pageSize, countRef.current + 2)
    const page = await api.page(tid, limit).catch(() => null)
    if (!page || ticket !== inflight.current || tid !== activeRef.current) return
    applyPage(page)
  }, [pageSize, applyPage])

  const nextBeforeRef = useRef(nextBefore)
  nextBeforeRef.current = nextBefore
  const loadingOlderRef = useRef(loadingOlder)
  loadingOlderRef.current = loadingOlder

  const loadOlder = useCallback(async () => {
    const tid = activeRef.current
    const nb = nextBeforeRef.current
    if (!tid || !nb || loadingOlderRef.current) return
    loadingOlderRef.current = true
    setLoadingOlder(true)
    try {
      const page = await api.page(tid, pageSize, nb)
      if (tid !== activeRef.current) return
      setMessages(prev => {
        const seen = new Set(prev.map(m => m.msg_id))
        return [...page.messages.filter(m => !seen.has(m.msg_id)), ...prev]
      })
      setHasMore(page.has_more)
      setNextBefore(page.next_before)
      setLoads(l => [...l.slice(-19), { at: Date.now(), count: page.messages.length, elapsed_us: page.elapsed_us, older: true, has_more: page.has_more }])
    } catch (e) {
      toast.error('Could not load older messages', { description: String((e as Error).message) })
    } finally {
      loadingOlderRef.current = false
      setLoadingOlder(false)
    }
  }, [pageSize])

  const refreshQueue = useCallback(async () => {
    const tid = activeRef.current
    if (!tid) return
    const r = await api.queue(tid).catch(() => null)
    if (r && tid === activeRef.current) setQueue(r.items)
  }, [])

  const select = useCallback((id: string) => {
    if (id === activeRef.current) return
    setActiveId(id)
  }, [])

  const selectWorktree = useCallback((id: string) => {
    if (id === activeWorktreeRef.current) return
    setActiveWorktreeId(id)
  }, [])

  useEffect(() => {
    try {
      if (activeId) localStorage.setItem('ondb-active', activeId)
    } catch {
      return
    }
  }, [activeId])

  useEffect(() => {
    setMessages([])
    setQueue([])
    setLoads([])
    setHasMore(false)
    setNextBefore(null)
    setHeadPage(null)
    headPageRef.current = null
    optimisticBranchRef.current = false
    setPageLoaded(false)
    countRef.current = 0
    if (!activeId) return
    refreshPage()
    refreshQueue()
  }, [activeId, refreshPage, refreshQueue])

  const createSession = useCallback(
    async (title = 'New session', provider = 'mock', model: string | null = 'sim-native-v1') => {
      const r = await run('Could not create session', () => api.createThread(title, provider, model, activeWorktreeRef.current))
      if (!r) return null
      await refreshSessions()
      setActiveId(r.thread_id)
      return r.thread_id
    },
    [run, refreshSessions],
  )

  const onFilesChanged = useCallback((fn: (ev: FilesChangedEvent) => void) => {
    filesChangedListeners.current.add(fn)
    return () => {
      filesChangedListeners.current.delete(fn)
    }
  }, [])

  useEffect(() => {
    refreshInfo()
    refreshSessions()
    refreshWorktrees()
    api.allModels().then(r => seedCatalogs(r.catalogs)).catch(() => undefined)
    loadModels('mock')
  }, [refreshInfo, refreshSessions, refreshWorktrees])

  const debounce = useCallback((key: string, fn: () => void, ms = 60) => {
    clearTimeout(timers.current[key])
    timers.current[key] = setTimeout(fn, ms)
  }, [])

  const handlers = useRef({ refreshPage, refreshQueue, refreshSessions, refreshWorktrees, refreshInfo, debounce, flushDeferredFiles })
  handlers.current = { refreshPage, refreshQueue, refreshSessions, refreshWorktrees, refreshInfo, debounce, flushDeferredFiles }

  useEffect(() => {
    let es: EventSource | null = null
    let retry: ReturnType<typeof setTimeout> | undefined
    let closed = false
    const connect = () => {
      setConn('connecting')
      es = new EventSource('/api/events')
      es.onopen = () => {
        setConn('live')
        const h = handlers.current
        h.refreshInfo()
        h.refreshSessions()
        h.refreshWorktrees()
        h.refreshPage()
        h.refreshQueue()
      }
      es.onerror = () => {
        setConn('offline')
        es?.close()
        if (!closed) retry = setTimeout(connect, 1500)
      }
      es.onmessage = ev => {
        let msg: ServerEvent
        try {
          msg = JSON.parse(ev.data)
        } catch {
          return
        }
        const h = handlers.current
        const isActive = 'thread_id' in msg && msg.thread_id === activeRef.current
        switch (msg.type) {
          case 'models_updated':
            api.models(msg.provider).then(c => seedCatalogs({ [msg.provider]: c })).catch(() => undefined)
            break
          case 'worktrees_updated':
            h.debounce('worktrees', h.refreshWorktrees)
            h.debounce('info', h.refreshInfo, 200)
            break
          case 'session_updated':
            h.debounce('sessions', h.refreshSessions)
            if (isActive) {
              if (!optimisticBranchRef.current && (msg.head_page === undefined || msg.head_page !== headPageRef.current)) {
                h.debounce('page', h.refreshPage)
              }
              h.debounce('queue', h.refreshQueue)
            }
            break
          case 'queue_updated':
            if (isActive) h.debounce('queue', h.refreshQueue)
            h.debounce('sessions', h.refreshSessions)
            break
          case 'turn_completed': {
            const tid = msg.thread_id
            const at = Date.now()
            setLive(prev => {
              let changed = false
              const next: Record<string, LiveTrace> = {}
              for (const [k, v] of Object.entries(prev)) {
                if (v.thread_id === tid && v.ended_ms == null) {
                  next[k] = { ...v, ended_ms: at }
                  changed = true
                } else next[k] = v
              }
              return changed ? next : prev
            })
            h.debounce('sessions', h.refreshSessions)
            h.debounce('info', h.refreshInfo, 200)
            if (isActive) {
              h.debounce('page', h.refreshPage, 20)
              h.debounce('queue', h.refreshQueue)
            }
            break
          }
          case 'files_changed': {
            deferredFilesRef.current.push(msg)
            h.debounce('info', h.refreshInfo, 200)
            if (msg.source === 'branch' || msg.source === 'rollback') {
              if (optimisticBranchRef.current) {
                requestAnimationFrame(() => h.flushDeferredFiles())
              } else {
                h.debounce('deferredFiles', h.flushDeferredFiles, 120)
              }
            } else {
              h.flushDeferredFiles()
            }
            break
          }
          case 'workspace_updated':
            h.debounce(
              'workspaceTick',
              () => {
                startTransition(() => setWorkspaceTick(x => x + 1))
                h.debounce('info', h.refreshInfo, 200)
              },
              30,
            )
            break
          case 'v2_updated':
          case 'v2_trigger_fired':
            h.debounce(
              'v2Tick',
              () => {
                startTransition(() => setV2Tick(x => x + 1))
              },
              60,
            )
            break
          case 'turn_delta': {
            const d = msg
            const key = d.msg_id ?? `live:${d.thread_id}`
            if (d.kind === 'turn_started') {
              setLive(prev => ({ ...prev, [key]: emptyLive(d, key) }))
              if (isActive) h.debounce('page', h.refreshPage, 10)
              h.debounce('sessions', h.refreshSessions)
              break
            }
            setLive(prev => {
              const cur = prev[key] ?? emptyLive(d, key)
              return { ...prev, [key]: applyDelta(cur, d) }
            })
            if (d.kind === 'steer_injected' || d.kind === 'steer_fallback') {
              if (isActive) h.debounce('queue', h.refreshQueue)
            }
            break
          }
        }
      }
    }
    connect()
    return () => {
      closed = true
      clearTimeout(retry)
      es?.close()
    }
  }, [])

  const providers = useMemo(() => [SIMULATOR, ...(info?.providers ?? [])], [info])
  const active = useMemo(() => sessions.find(s => s.thread_id === activeId) ?? null, [sessions, activeId])
  const activeWorktree = useMemo(
    () => worktrees.find(w => w.id === activeWorktreeId) ?? worktrees.find(w => w.is_primary) ?? worktrees[0] ?? null,
    [worktrees, activeWorktreeId],
  )

  const value = useMemo<Store>(
    () => ({
      info,
      providers,
      sessions,
      worktrees,
      activeWorktreeId,
      activeWorktree,
      activeId,
      active,
      queue,
      workspaceTick,
      v2Tick,
      fileActivity,
      fileFeed,
      conn,
      pageSize,
      select,
      selectWorktree,
      onFilesChanged,
      refreshSessions,
      refreshWorktrees,
      refreshInfo,
      refreshPage,
      applyPage,
      reconcilePage,
      loadOlder,
      refreshQueue,
      createSession,
      run,
    }),
    [
      info,
      providers,
      sessions,
      worktrees,
      activeWorktreeId,
      activeWorktree,
      activeId,
      active,
      queue,
      workspaceTick,
      v2Tick,
      fileActivity,
      fileFeed,
      conn,
      pageSize,
      select,
      selectWorktree,
      onFilesChanged,
      refreshSessions,
      refreshWorktrees,
      refreshInfo,
      refreshPage,
      applyPage,
      reconcilePage,
      loadOlder,
      refreshQueue,
      createSession,
      run,
    ],
  )

  const pageValue = useMemo<ThreadPageState>(
    () => ({
      messages,
      hasMore,
      nextBefore,
      headPage,
      loads,
      loadingOlder,
      pageLoaded,
      live,
    }),
    [messages, hasMore, nextBefore, headPage, loads, loadingOlder, pageLoaded, live],
  )

  return (
    <Ctx.Provider value={value}>
      <ThreadPageCtx.Provider value={pageValue}>{children}</ThreadPageCtx.Provider>
    </Ctx.Provider>
  )
}
