import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from 'react'
import { Escape, fontEpoch, MugenInstance, MugenVList, useMugenSelector, useMugenVirtualizer, type MugenHeightCache } from '@wingleeio/mugen'
import { ArrowDown, Layers, Loader2, PanelLeft, PanelRight, RotateCcw, Sparkles } from 'lucide-react'
import { toast } from 'sonner'
import { api, type Message, type Page } from '@/lib/api'
import { providerName } from '@/lib/catalog'
import { micros, shortId } from '@/lib/format'
import { useStore, useThreadPage } from '@/lib/store'
import { buildTurns, type Turn, type TurnBlock } from '@/lib/turns'
import { cn } from '@/lib/utils'
import { Composer, type ComposerHandle } from './composer'
import { TurnCtx, TurnRow, type TurnActions } from './turn-row'
import { ForkBar } from '../fork-bar'
import { Button } from '../ui/button'
import { Tip } from '../ui/tooltip'
import { Kbd } from '../ui/kbd'
import { Popover, PopoverContent, PopoverTrigger } from '../ui/popover'
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogTitle } from '../ui/alert-dialog'

const HEADER_H = 56
const CLEARANCE = 188

function blocksRevision(blocks: TurnBlock[]) {
  let rev = blocks.length
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i]
    if (b.kind === 'markdown' || b.kind === 'error') {
      rev = (rev * 31 + b.text.length) | 0
    } else if (b.kind === 'reasoning') {
      rev = (rev * 31 + b.text.length + (b.done ? 1 : 0)) | 0
    } else if (b.kind === 'steer') {
      rev = (rev * 31 + b.steer.prompt.length + (b.steer.at_ms & 0xffff)) | 0
    } else {
      for (let j = 0; j < b.tools.length; j++) {
        const x = b.tools[j]
        rev = (rev * 31 + x.input.length + x.output.length + (x.ended_ms ? 7 : 0) + (x.is_error ? 3 : 0)) | 0
      }
    }
  }
  return rev
}

function turnSig(t: Turn) {
  const m = t.msg
  if (t.streaming || t.msg.status === 'running') return `${t.id}|live|${t.text.length}|${blocksRevision(t.blocks)}|${t.blocks.length}`
  return `${t.id}|${m.status}|${m.updated_ms ?? 0}|${m.sibling_index ?? 0}|${m.siblings?.length ?? 0}|${t.blocks.length}|${t.text.length}|${blocksRevision(t.blocks)}`
}

function useStableTurns(turns: Turn[]) {
  const cache = useRef(new Map<string, { sig: string; turn: Turn }>())
  const prev = useRef<Turn[]>([])
  return useMemo(() => {
    const next = new Map<string, { sig: string; turn: Turn }>()
    let same = turns.length === prev.current.length
    const out = turns.map((t, i) => {
      const sig = turnSig(t)
      const hit = cache.current.get(t.id)
      const turn = hit && hit.sig === sig ? hit.turn : t
      next.set(t.id, { sig, turn })
      if (prev.current[i] !== turn) same = false
      return turn
    })
    cache.current = next
    if (same) return prev.current
    prev.current = out
    return out
  }, [turns])
}

const scrollerOf = (list: MugenInstance<Turn>) => (list as unknown as { scrollEl: HTMLElement | null }).scrollEl
const interruptStick = (list: MugenInstance<Turn>) => (list as unknown as { stickInterrupt?: () => void }).stickInterrupt?.()

function smoothScrollToBottom(list: MugenInstance<Turn>, stick: boolean) {
  if (stick) {
    list.scrollToBottom({ behavior: 'smooth' })
    return
  }
  interruptStick(list)
  const el = scrollerOf(list)
  if (!el) return
  const target = Math.max(0, el.scrollHeight - el.clientHeight)
  const glideMax = el.clientHeight * 2.5
  if (el.clientHeight > 0 && target - el.scrollTop > glideMax) {
    el.scrollTop = target - glideMax
  }
  el.scrollTo({ top: target, behavior: 'smooth' })
}

function mergePrefix(page: Page, prefix: Message[], prevHasMore: boolean, prevNextBefore: string | null): Page {
  if (prefix.length === 0 || page.messages.length === 0) return page
  if (page.messages.some(m => m.msg_id === prefix[0].msg_id)) return page
  const attach = prefix.findIndex(m => m.msg_id === page.messages[0].parent_id)
  if (attach < 0) return page
  return {
    ...page,
    messages: [...prefix.slice(0, attach + 1), ...page.messages],
    has_more: prevHasMore,
    next_before: prevNextBefore,
  }
}

function sameMessages(a: Message[], b: Message[]) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    const x = a[i]
    const y = b[i]
    if (
      x.msg_id !== y.msg_id ||
      x.status !== y.status ||
      x.updated_ms !== y.updated_ms ||
      x.content !== y.content ||
      x.sibling_index !== y.sibling_index ||
      (x.siblings?.length ?? 0) !== (y.siblings?.length ?? 0)
    ) {
      return false
    }
  }
  return true
}

function cacheBranchPage(cache: Map<string, Page>, page: Page) {
  for (const m of page.messages) {
    if ((m.siblings?.length ?? 0) > 1) {
      cache.set(m.msg_id, page)
    }
  }
}

interface PendingBranch {
  seq: number
  id: string
  fromId: string
  limit: number
  fromMsgId?: string
  prefix: Message[]
  prevHasMore: boolean
  prevNextBefore: string | null
  anchor: { id: string; bottomOffset: number } | null
  optimisticPage: Page | null
  fallbackPage: Page
}

export function ThreadView({ composerRef, onShowChanges, sidebarOpen, onToggleSidebar, inspectorOpen, onToggleInspector }: { composerRef: RefObject<ComposerHandle | null>; onShowChanges: (m: Message) => void; sidebarOpen: boolean; onToggleSidebar: () => void; inspectorOpen: boolean; onToggleInspector: () => void }) {
  const s = useStore()
  const { active } = s
  if (!active) return <EmptyState sidebarOpen={sidebarOpen} onToggleSidebar={onToggleSidebar} />
  return <Thread key={active.thread_id} composerRef={composerRef} onShowChanges={onShowChanges} sidebarOpen={sidebarOpen} onToggleSidebar={onToggleSidebar} inspectorOpen={inspectorOpen} onToggleInspector={onToggleInspector} />
}

function Thread({ composerRef, onShowChanges, sidebarOpen, onToggleSidebar, inspectorOpen, onToggleInspector }: { composerRef: RefObject<ComposerHandle | null>; onShowChanges: (m: Message) => void; sidebarOpen: boolean; onToggleSidebar: () => void; inspectorOpen: boolean; onToggleInspector: () => void }) {
  const s = useStore()
  const p = useThreadPage()
  const active = s.active!
  const { providers, run, refreshSessions } = s
  const { messages, live } = p
  const [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState<Message | null>(null)
  const [editing, setEditing] = useState<Message | null>(null)

  const raw = useMemo(() => buildTurns(messages, live, active.thread_id), [messages, live, active.thread_id])
  const items = useStableTurns(raw)
  const list = useMugenVirtualizer({ items })
  const running = active.status === 'running' || active.status === 'steering' || items.some(t => t.streaming)
  const runningRef = useRef(running)
  runningRef.current = running
  const heightMapRef = useRef(new Map<string, number>())
  const heightCache = useMemo<MugenHeightCache>(
    () => ({
      get(key, width) {
        if (runningRef.current) return undefined
        return heightMapRef.current.get(`${fontEpoch()}:${width}:${key}`)
      },
      set(key, width, height) {
        if (runningRef.current) return
        heightMapRef.current.set(`${fontEpoch()}:${width}:${key}`, height)
      },
    }),
    [],
  )
  list.heightCache = heightCache

  const lastUser = useMemo(() => {
    for (let i = items.length - 1; i >= 0; i--) if (items[i].role === 'user') return i
    return -1
  }, [items])

  const pin = useRef<{ id: string; bottomOffset: number } | null>(null)
  const pinFloor = useRef(0)
  const branchCacheRef = useRef(new Map<string, Page>())
  const prefetchedRef = useRef(new Set<string>())
  const switchSeqRef = useRef(0)
  const branchInFlightRef = useRef(false)
  const queuedBranchRef = useRef<PendingBranch | null>(null)
  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])
  const rowBottom = useCallback(
    (i: number) => (i + 1 < list.length ? list.offsetOf(i + 1) : list.topHeight() + list.itemsHeight()),
    [list],
  )

  const runway = () => {
    try {
      const vh = list.getScrollState().viewportHeight
      if (!vh) return CLEARANCE
      const contentEnd = list.topHeight() + list.itemsHeight()
      const base = lastUser < 0 ? CLEARANCE : Math.max(CLEARANCE, Math.round(vh - (contentEnd - list.offsetOf(lastUser)) - HEADER_H))
      const p = pin.current
      if (p) {
        const idx = items.findIndex(t => t.id === p.id)
        if (idx >= 0) {
          pinFloor.current = Math.max(0, rowBottom(idx) - p.bottomOffset)
        }
      }
      const floor = pinFloor.current > 0 ? Math.max(CLEARANCE, Math.round(pinFloor.current + vh - contentEnd)) : CLEARANCE
      return Math.max(base, floor)
    } catch {
      return CLEARANCE
    }
  }

  const glide = useRef<{ from: number } | null>(null)
  const wasRunning = useRef(running)
  useLayoutEffect(() => {
    const prev = wasRunning.current
    wasRunning.current = running
    if (running && !prev) {
      branchCacheRef.current.clear()
      prefetchedRef.current.clear()
      heightMapRef.current.clear()
    }
    if (!running) {
      interruptStick(list)
    } else if (!prev && !glide.current) {
      const el = scrollerOf(list)
      if (el && el.scrollHeight - el.clientHeight - el.scrollTop <= 70) {
        list.scrollToBottom({ behavior: 'auto' })
      }
    }
  }, [running, list])

  useEffect(() => {
    if (running || !p.pageLoaded || messages.length === 0) return
    const currentSnapshot: Page = {
      messages,
      has_more: p.hasMore,
      next_before: p.nextBefore,
      head_page: p.headPage,
      elapsed_us: 0,
    }
    cacheBranchPage(branchCacheRef.current, currentSnapshot)

    const missing: { sibId: string; fromMsgId?: string; prefix: Message[] }[] = []
    for (let i = 0; i < messages.length; i++) {
      const m = messages[i]
      if ((m.siblings?.length ?? 0) < 2) continue
      const prefix = i > 0 ? messages.slice(0, i) : []
      const fromMsgId = i > 0 ? messages[0]?.msg_id : undefined
      for (const sibId of m.siblings) {
        if (sibId === m.msg_id) continue
        if (branchCacheRef.current.has(sibId) || prefetchedRef.current.has(sibId)) continue
        missing.push({ sibId, fromMsgId, prefix })
      }
    }
    if (!missing.length) return

    let alive = true
    const tid = active.thread_id
    const limit = Math.max(s.pageSize, messages.length + 2)
    const prevHasMore = p.hasMore
    const prevNextBefore = p.nextBefore
    const warmTimers: ReturnType<typeof setTimeout>[] = []
    const warmBranchMeasurements = (msgs: Message[]) => {
      const t = setTimeout(() => {
        if (!alive || runningRef.current) return
        const cw = list.contentWidth()
        if (!cw) return
        const vh = list.getScrollState().viewportHeight || 800
        const rootPx = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
        const warmTurns = buildTurns(msgs, {}, tid)
        const warm = new MugenInstance<Turn>()
        warm.heightCache = heightCache
        warm.configure({
          getKey: item => item.id,
          render: TurnRow,
          defaults: { font: '15px Geist, sans-serif', lineHeight: 26 },
          maxW: 768,
        })
        warm.setItems(warmTurns)
        warm.setViewport(cw, vh, rootPx)
        warm.sync()
        warm.setItems([])
        warm.sync()
      }, 16)
      warmTimers.push(t)
    }
    const timer = setTimeout(() => {
      for (const item of missing) {
        if (!alive || branchCacheRef.current.has(item.sibId) || prefetchedRef.current.has(item.sibId)) continue
        prefetchedRef.current.add(item.sibId)
        api
          .branchPreview(tid, item.sibId, limit, item.fromMsgId ?? item.sibId)
          .then(page => {
            if (!alive || runningRef.current) return
            if (!page.messages.some(x => x.msg_id === item.sibId)) return
            const merged = mergePrefix(page, item.prefix, prevHasMore, prevNextBefore)
            cacheBranchPage(branchCacheRef.current, merged)
            warmBranchMeasurements(merged.messages)
          })
          .catch(() => {
            prefetchedRef.current.delete(item.sibId)
          })
      }
    }, 60)
    return () => {
      alive = false
      clearTimeout(timer)
      for (const t of warmTimers) clearTimeout(t)
    }
  }, [messages, running, p.pageLoaded, p.hasMore, p.nextBefore, p.headPage, s.pageSize, active.thread_id, list, heightCache])

  useLayoutEffect(() => {
    const g = glide.current
    if (!g || lastUser < 0 || lastUser <= g.from) return
    glide.current = null
    requestAnimationFrame(() => requestAnimationFrame(() => smoothScrollToBottom(list, runningRef.current)))
  }, [items, lastUser, list])

  useLayoutEffect(() => {
    const p = pin.current
    if (!p) return
    const index = items.findIndex(t => t.id === p.id)
    pin.current = null
    if (index < 0) return
    interruptStick(list)
    const el = scrollerOf(list)
    if (!el) return
    const target = Math.max(0, rowBottom(index) - p.bottomOffset)
    const delta = target - list.scrollTop
    if (Math.abs(delta) > 0.5) {
      if (Math.abs(delta) > 100) {
        const anchor = (list as unknown as { scrollAnchor?: ((d: number) => void) | null }).scrollAnchor
        if (anchor) anchor(target - el.scrollTop)
        else {
          el.scrollTop = target
          list.setScrollTop(target)
        }
      } else {
        el.scrollTop = target
        list.setScrollTop(target)
      }
    }
  }, [items, list, rowBottom])

  const onConfig = useCallback(
    async (provider: string, model: string | null) => {
      await run('Could not switch harness', () => api.config(active.thread_id, { provider, model: model ?? '' }))
      refreshSessions()
      toast.success(`Now using ${providerName(provider, providers)}`, { description: model ?? 'Harness default model' })
    },
    [active.thread_id, run, refreshSessions, providers],
  )

  const drainBranchQueue = useCallback(async () => {
    if (branchInFlightRef.current) return
    branchInFlightRef.current = true
    try {
      while (queuedBranchRef.current) {
        const job = queuedBranchRef.current
        queuedBranchRef.current = null
        const r = await run('Branch switch failed', () => api.branch(active.thread_id, job.id, job.limit, job.fromMsgId))
        if (!mountedRef.current || job.seq !== switchSeqRef.current) continue
        if (!r) {
          if (job.optimisticPage) {
            if (job.anchor) pin.current = { id: job.fromId, bottomOffset: job.anchor.bottomOffset }
            s.applyPage(job.fallbackPage)
          }
          continue
        }
        const serverPage = mergePrefix(r.page, job.prefix, job.prevHasMore, job.prevNextBefore)
        cacheBranchPage(branchCacheRef.current, serverPage)
        if (job.optimisticPage && sameMessages(job.optimisticPage.messages, serverPage.messages)) {
          s.reconcilePage(serverPage)
        } else {
          if (job.anchor && serverPage.messages.some(m => m.msg_id === job.id)) {
            pin.current = job.anchor
          }
          s.applyPage(serverPage)
        }
        requestAnimationFrame(() => {
          toast(`Switched branch · ${micros(r.elapsed_us)}`, { description: `Workspace time-travelled to leaf ${shortId(r.leaf_msg_id)}` })
        })
      }
    } finally {
      branchInFlightRef.current = false
    }
  }, [active.thread_id, run, s.applyPage, s.reconcilePage])

  const actions: TurnActions = useMemo(
    () => ({
      providers,
      busy: busy || running,
      edit: msg => {
        setEditing(msg)
        composerRef.current?.setText(msg.content)
      },
      switchTo: (id, fromId) => {
        const seq = ++switchSeqRef.current
        const fromMsgIdx = messages.findIndex(m => m.msg_id === fromId)
        const limit = Math.max(s.pageSize, messages.length + 2)
        const fromMsgId = fromMsgIdx > 0 ? messages[0]?.msg_id : id
        const from = items.findIndex(t => t.id === fromId)
        const prefix = fromMsgIdx > 0 ? messages.slice(0, fromMsgIdx) : []
        const prevHasMore = p.hasMore
        const prevNextBefore = p.nextBefore
        const anchor = from >= 0 ? { id, bottomOffset: rowBottom(from) - list.scrollTop } : null
        const fallbackPage: Page = {
          messages,
          has_more: prevHasMore,
          next_before: prevNextBefore,
          head_page: p.headPage,
          elapsed_us: 0,
        }
        cacheBranchPage(branchCacheRef.current, fallbackPage)

        const cached = branchCacheRef.current.get(id)
        let optimisticPage: Page | null = null
        if (cached && cached.messages.some(m => m.msg_id === id)) {
          optimisticPage = mergePrefix(cached, prefix, prevHasMore, prevNextBefore)
          if (anchor) pin.current = anchor
          s.applyPage(optimisticPage, { optimistic: true })
        }

        queuedBranchRef.current = {
          seq,
          id,
          fromId,
          limit,
          fromMsgId,
          prefix,
          prevHasMore,
          prevNextBefore,
          anchor,
          optimisticPage,
          fallbackPage,
        }
        void drainBranchQueue()
      },
      rollback: msg => setConfirm(msg),
      showChanges: onShowChanges,
    }),
    [providers, busy, running, items, rowBottom, list, s.pageSize, p.hasMore, p.nextBefore, p.headPage, s.applyPage, messages, onShowChanges, composerRef, drainBranchQueue],
  )

  const onSubmitted = useCallback(
    (kind: 'send' | 'queue' | 'steer' | 'edit') => {
      pinFloor.current = 0
      branchCacheRef.current.clear()
      prefetchedRef.current.clear()
      heightMapRef.current.clear()
      if (kind === 'send' || kind === 'edit') glide.current = { from: kind === 'edit' ? -1 : lastUser }
      if (kind === 'edit') toast.success('Forked a new branch', { description: 'Workspace rewound crash-safely, then the turn re-ran.' })
    },
    [lastUser],
  )

  const doRollback = async () => {
    const msg = confirm
    if (!msg) return
    setConfirm(null)
    pinFloor.current = 0
    branchCacheRef.current.clear()
    prefetchedRef.current.clear()
    heightMapRef.current.clear()
    setBusy(true)
    const limit = Math.max(s.pageSize, messages.length + 2)
    const r = await run('Rollback failed', () => api.rollback(active.thread_id, msg.msg_id, limit))
    setBusy(false)
    if (r) {
      s.applyPage(r.page)
      toast.success(`Rolled back · ${micros(r.elapsed_us)}`, { description: 'Intent journaled, workspace restored, branch re-sealed.' })
    }
  }

  const lastLoad = p.loads.at(-1)

  return (
    <TurnCtx.Provider value={actions}>
      <div className="relative min-w-0 flex-1">
        <MugenVList
          instance={list}
          getKey={t => t.id}
          render={TurnRow}
          font="15px Geist, sans-serif"
          lineHeight={26}
          maxW={768}
          overscan={120}
          initialScroll="bottom"
          stickToBottom={running}
          onTopReached={() => {
            if (p.hasMore) s.loadOlder()
          }}
          topReachedThreshold={240}
          renderTop={() => (
            <Escape height={HEADER_H + 56}>
              <TopSlot hasMore={p.hasMore} loading={p.loadingOlder} lastUs={lastLoad?.elapsed_us} count={messages.length} headPage={p.headPage} onLoad={s.loadOlder} ready={p.pageLoaded} />
            </Escape>
          )}
          renderBottom={() => <Escape height={runway()}><div /></Escape>}
          className="h-full"
        />
        {p.pageLoaded && !items.length ? <FirstRun /> : null}
        <Header
          title={active.title}
          threadId={active.thread_id}
          sidebarOpen={sidebarOpen}
          onToggleSidebar={onToggleSidebar}
          inspectorOpen={inspectorOpen}
          onToggleInspector={onToggleInspector}
        />
        <Composer
          ref={composerRef}
          session={active}
          running={running}
          providers={providers}
          editing={editing}
          cancelEdit={() => setEditing(null)}
          onConfig={onConfig}
          onSubmitted={onSubmitted}
          aboveInput={<ScrollToBottom list={list} running={running} />}
        />
      </div>
      <AlertDialog open={!!confirm} onOpenChange={o => !o && setConfirm(null)}>
        <AlertDialogContent>
          <div className="flex size-9 items-center justify-center rounded-xl bg-amber-soft text-amber">
            <RotateCcw className="size-4" />
          </div>
          <div className="flex flex-col gap-1.5">
            <AlertDialogTitle>Roll back to this turn?</AlertDialogTitle>
            <AlertDialogDescription>
              0ndb journals a rollback intent, rewinds the CRDT workspace to the exact version sealed after this turn, and re-seals the Merkle page chain. Later turns stay in the WAL — reachable again by switching branches.
            </AlertDialogDescription>
          </div>
          <div className="flex justify-end gap-2">
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={doRollback}>Roll back</AlertDialogAction>
          </div>
        </AlertDialogContent>
      </AlertDialog>
    </TurnCtx.Provider>
  )
}

function ScrollToBottom({ list, running }: { list: MugenInstance<Turn>; running: boolean }) {
  const away = useMugenSelector(list, st => st.distanceFromBottom > 200)
  return (
    <button
      type="button"
      data-hidden={!away}
      onClick={() => smoothScrollToBottom(list, running)}
      className="inline-flex items-center gap-1.5 rounded-full border border-border bg-background py-1.5 pr-3.5 pl-2.5 text-xs text-muted-foreground shadow-sm transition-all duration-200 hover:text-foreground data-[hidden=true]:pointer-events-none data-[hidden=true]:translate-y-1 data-[hidden=true]:opacity-0"
    >
      <ArrowDown className="size-3" />
      Scroll to bottom
    </button>
  )
}

function TopSlot({ hasMore, loading, lastUs, count, headPage, onLoad, ready }: { hasMore: boolean; loading: boolean; lastUs?: number; count: number; headPage: string | null; onLoad: () => void; ready: boolean }) {
  return (
    <div className="flex h-full items-end justify-center pb-3" style={{ paddingTop: HEADER_H }}>
      {!ready ? null : hasMore ? (
        <button onClick={onLoad} className="flex items-center gap-2 font-mono text-[11.5px] text-muted-foreground transition hover:text-foreground">
          {loading ? <Loader2 className="size-3 animate-spin" /> : <Layers className="size-3" />}
          {loading ? 'walking prev_page…' : 'scroll up for older Merkle pages'}
          {lastUs != null ? <span className="text-muted-foreground/60">· last {micros(lastUs)}</span> : null}
        </button>
      ) : count ? (
        <span className="flex items-center gap-2 font-mono text-[11.5px] text-muted-foreground/70">
          <Layers className="size-3" /> beginning of branch · genesis {headPage ? shortId(headPage, 8) : '—'}
        </span>
      ) : null}
    </div>
  )
}

function Header({ title, threadId, sidebarOpen, onToggleSidebar, inspectorOpen, onToggleInspector }: { title: string; threadId: string; sidebarOpen: boolean; onToggleSidebar: () => void; inspectorOpen: boolean; onToggleInspector: () => void }) {
  const { run, refreshSessions } = useStore()
  return (
    <div className="pointer-events-none absolute inset-x-0 top-0 z-10 flex items-center gap-2 bg-gradient-to-b from-background from-40% to-transparent px-4" style={{ height: HEADER_H + 12 }}>
      <div className="pointer-events-auto flex min-w-0 items-center gap-1.5">
        <div className="flex items-center rounded-xl border border-border bg-background/70 p-1 shadow-sm backdrop-blur-md">
          <Tip label={sidebarOpen ? 'Hide sidebar' : 'Show sidebar'} shortcut="⌘B">
            <Button variant="ghost" size="icon" className={cn('size-8 rounded-lg', sidebarOpen && 'text-foreground')} onClick={onToggleSidebar} aria-label={sidebarOpen ? 'Hide sidebar' : 'Show sidebar'}>
              <PanelLeft className="size-4" />
            </Button>
          </Tip>
        </div>
        <TitleEditor key={threadId} title={title} onSave={t => run('Rename failed', () => api.config(threadId, { title: t })).then(refreshSessions)} />
      </div>
      <div className="pointer-events-auto ml-auto flex items-center gap-1.5">
        <ForkBar />
        <div className="flex items-center gap-1 rounded-xl border border-border bg-background/70 p-1 shadow-sm backdrop-blur-md">
          <PageReadout />
          <Tip label={inspectorOpen ? 'Hide workspace' : 'Show workspace'} shortcut="⌘.">
            <Button variant="ghost" size="icon" className={cn('size-8 rounded-lg', inspectorOpen && 'text-foreground')} onClick={onToggleInspector} aria-label={inspectorOpen ? 'Hide workspace' : 'Show workspace'}>
              <PanelRight className="size-4" />
            </Button>
          </Tip>
        </div>
      </div>
    </div>
  )
}

function TitleEditor({ title, onSave }: { title: string; onSave: (t: string) => void }) {
  const [v, setV] = useState(title)
  const [editing, setEditing] = useState(false)
  useEffect(() => setV(title), [title])
  if (!editing)
    return (
      <button onClick={() => setEditing(true)} className="min-w-0 truncate rounded-lg px-2 py-1 text-[14px] font-medium transition-colors hover:bg-accent" title="Rename">
        {title}
      </button>
    )
  const commit = () => {
    setEditing(false)
    if (v.trim() && v.trim() !== title) onSave(v.trim())
    else setV(title)
  }
  return (
    <input
      autoFocus
      value={v}
      onChange={e => setV(e.target.value)}
      onBlur={commit}
      onKeyDown={e => {
        if (e.key === 'Enter') commit()
        if (e.key === 'Escape') {
          setV(title)
          setEditing(false)
        }
      }}
      className="h-8 w-80 max-w-full rounded-lg border border-ring/50 bg-background px-2 text-[14px] font-medium outline-none"
    />
  )
}

function PageReadout() {
  const { pageSize } = useStore()
  const p = useThreadPage()
  const last = p.loads.at(-1)
  if (!last) return null
  const avg = Math.round(p.loads.reduce((a, l) => a + l.elapsed_us, 0) / p.loads.length)
  const max = Math.max(...p.loads.map(l => l.elapsed_us), 1)
  return (
    <Popover>
      <PopoverTrigger asChild>
        <button className="flex h-8 items-center gap-1.5 rounded-lg px-2 text-[12px] text-muted-foreground transition hover:bg-accent hover:text-foreground">
          <Layers className="size-3.5" />
          <span className="font-mono tabular">{micros(last.elapsed_us)}</span>
        </button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-80 p-0">
        <div className="border-b border-border px-4 py-3">
          <div className="text-[13px] font-medium">Merkle page loading</div>
          <div className="mt-0.5 text-[12px] leading-relaxed text-muted-foreground">
            Messages are sealed into content-addressed pages of <span className="font-mono text-foreground">{pageSize}</span>. Older pages stream in as you scroll, walking <span className="font-mono">prev_page</span> hashes — the list stays anchored.
          </div>
        </div>
        <div className="grid grid-cols-3 gap-px bg-border">
          {[
            ['last', micros(last.elapsed_us)],
            ['average', micros(avg)],
            ['loaded', String(p.messages.length)],
          ].map(([k, v]) => (
            <div key={k} className="bg-popover px-4 py-2.5">
              <div className="text-[10.5px] text-muted-foreground">{k}</div>
              <div className="font-mono text-[13px] tabular">{v}</div>
            </div>
          ))}
        </div>
        <div className="flex h-16 items-end gap-[3px] border-t border-border px-4 pt-3 pb-2">
          {p.loads.map((l, i) => (
            <Tip key={i} label={`${l.older ? 'older page' : 'head refresh'} · ${l.count} msgs · ${micros(l.elapsed_us)}`}>
              <span className={cn('min-h-[3px] flex-1 rounded-sm', l.older ? 'bg-amber/70' : 'bg-primary/70')} style={{ height: `${Math.max(8, (l.elapsed_us / max) * 100)}%` }} />
            </Tip>
          ))}
        </div>
        <div className="flex items-center gap-3 px-4 pb-3 text-[10.5px] text-muted-foreground">
          <span className="flex items-center gap-1"><span className="size-2 rounded-sm bg-primary/70" />head refresh</span>
          <span className="flex items-center gap-1"><span className="size-2 rounded-sm bg-amber/70" />older page</span>
          <span className="ml-auto font-mono">{p.headPage ? shortId(p.headPage, 10) : ''}</span>
        </div>
      </PopoverContent>
    </Popover>
  )
}

function FirstRun() {
  return (
    <div className="pointer-events-none absolute inset-x-0 top-[24%] flex flex-col items-center px-6 text-center animate-rise">
      <Sparkles className="size-5 text-primary" />
      <h2 className="mt-4 font-serif text-3xl text-foreground italic">A fresh, durable session.</h2>
      <p className="mt-2 max-w-md text-[13.5px] leading-relaxed text-muted-foreground">
        Every turn seals into the append-only WAL with its CRDT workspace version. Edit any prompt to fork, switch branches to time-travel files, and steer mid-turn.
      </p>
      <div className="mt-4 flex items-center gap-3 text-[11.5px] text-muted-foreground/70">
        <span className="flex items-center gap-1"><Kbd>⌘K</Kbd> commands</span>
        <span className="flex items-center gap-1"><Kbd>⌘/</Kbd> harness</span>
      </div>
    </div>
  )
}

function EmptyState({ sidebarOpen, onToggleSidebar }: { sidebarOpen: boolean; onToggleSidebar: () => void }) {
  const { createSession } = useStore()
  return (
    <div className="relative flex flex-1 flex-col items-center justify-center text-center">
      <div className="absolute top-3 left-4 flex items-center rounded-xl border border-border bg-background/70 p-1 shadow-sm backdrop-blur-md">
        <Tip label={sidebarOpen ? 'Hide sidebar' : 'Show sidebar'} shortcut="⌘B">
          <Button variant="ghost" size="icon" className={cn('size-8 rounded-lg', sidebarOpen && 'text-foreground')} onClick={onToggleSidebar} aria-label={sidebarOpen ? 'Hide sidebar' : 'Show sidebar'}>
            <PanelLeft className="size-4" />
          </Button>
        </Tip>
      </div>
      <h2 className="font-serif text-3xl text-foreground italic">Nothing here yet.</h2>
      <Button className="mt-5 h-9 rounded-xl" onClick={() => createSession()}>
        New session
      </Button>
    </div>
  )
}
