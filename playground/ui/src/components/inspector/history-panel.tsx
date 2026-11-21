import { useEffect, useMemo, useState } from 'react'
import { GitCommitHorizontal, Loader2, RefreshCw, X, FileDiff, CircleDot } from 'lucide-react'
import { api, type DiffFile, type HistoryBatch, type Message } from '@/lib/api'
import { providerName } from '@/lib/catalog'
import { ago, clock, micros, plural, shortId } from '@/lib/format'
import { useStore, useThreadPage } from '@/lib/store'
import { cn } from '@/lib/utils'
import { FileDiffCard } from '../diff-view'
import { HarnessGlyph } from '../harness-glyph'
import { Button } from '../ui/button'
import { Tip } from '../ui/tooltip'
import { actorStyle } from '@/lib/actors'

export function HistoryPanel({ diffMsg, setDiffMsg }: { diffMsg: Message | null; setDiffMsg: (m: Message | null) => void }) {
  const { workspaceTick, activeId, providers } = useStore()
  const { messages } = useThreadPage()
  const turns = useMemo(() => messages.filter(m => m.role === 'assistant' && m.status !== 'running').reverse(), [messages])

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto">
      <section className="px-3 pt-3">
        <div className="flex items-center pb-2">
          <span className="text-[11px] font-medium text-faint">Turn changes</span>
          {diffMsg ? (
            <Button size="xs" variant="ghost" className="ml-auto" onClick={() => setDiffMsg(null)}>
              <X className="size-3" /> Clear
            </Button>
          ) : null}
        </div>
        {diffMsg && activeId ? (
          <TurnDiff tid={activeId} msg={diffMsg} tick={workspaceTick} providers={providers} />
        ) : (
          <div className="flex flex-col gap-1">
            {turns.length ? (
              turns.map((m, i) => (
                <button key={m.msg_id} onClick={() => setDiffMsg(m)} className="group flex items-start gap-2.5 rounded-lg border border-transparent px-2 py-2 text-left transition hover:border-border hover:bg-card">
                  <HarnessGlyph slug={m.provider} size="sm" className="mt-0.5" />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-1.5 text-[12px]">
                      <span className="font-medium">Turn {turns.length - i}</span>
                      <span className="text-faint">·</span>
                      <span className="font-mono text-[10.5px] text-faint">{clock(m.created_ms)}</span>
                      {m.status !== 'completed' ? <span className="text-[10.5px] text-amber">{m.status}</span> : null}
                    </span>
                    <span className="mt-0.5 line-clamp-2 text-[12px] leading-snug text-muted-foreground">{m.content || '—'}</span>
                  </span>
                  <FileDiff className="mt-0.5 size-3.5 text-faint opacity-0 transition group-hover:opacity-100" />
                </button>
              ))
            ) : (
              <div className="rounded-lg border border-dashed border-border px-3 py-5 text-center text-[12px] text-muted-foreground">No completed turns on this branch yet.</div>
            )}
          </div>
        )}
      </section>
      <DagTimeline tick={workspaceTick} />
    </div>
  )
}

function TurnDiff({ tid, msg, tick, providers }: { tid: string; msg: Message; tick: number; providers: ReturnType<typeof useStore>['providers'] }) {
  const [state, setState] = useState<{ files: DiffFile[]; elapsed_us: number } | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    let alive = true
    setState(null)
    setError(null)
    api
      .diff(tid, msg.msg_id)
      .then(r => alive && setState(r))
      .catch(e => alive && setError(String(e.message ?? e)))
    return () => {
      alive = false
    }
  }, [tid, msg.msg_id, tick])
  return (
    <div className="flex flex-col gap-2 animate-rise">
      <div className="flex items-center gap-2 rounded-lg bg-muted/60 px-2.5 py-2 text-[12px]">
        <HarnessGlyph slug={msg.provider} size="sm" />
        <span className="font-medium">{providerName(msg.provider, providers)}</span>
        <span className="font-mono text-[10.5px] text-faint">{shortId(msg.msg_id)}</span>
        <span className="ml-auto font-mono text-[10.5px] text-faint">{state ? `pre → post · ${micros(state.elapsed_us)}` : ''}</span>
      </div>
      {error ? <div className="rounded-lg border border-destructive/25 bg-danger-soft/60 px-3 py-2 text-[12px] text-destructive">{error}</div> : null}
      {!state && !error ? (
        <div className="flex items-center gap-2 px-1 py-3 text-[12px] text-muted-foreground">
          <Loader2 className="size-3.5 animate-spin" /> Reading files at both causal versions…
        </div>
      ) : null}
      {state && !state.files.length ? <div className="rounded-lg border border-dashed border-border px-3 py-5 text-center text-[12px] text-muted-foreground">This turn didn’t change any files.</div> : null}
      {state?.files.map(f => <FileDiffCard key={f.path} {...f} />)}
    </div>
  )
}

function DagTimeline({ tick }: { tick: number }) {
  const [data, setData] = useState<{ total: number; elapsed_us: number; batches: HistoryBatch[] } | null>(null)
  const [error, setError] = useState(false)
  const [loading, setLoading] = useState(false)
  const load = () => {
    setLoading(true)
    api
      .history(120)
      .then(r => {
        setData(r)
        setError(false)
      })
      .catch(() => setError(true))
      .finally(() => setLoading(false))
  }
  useEffect(load, [tick])
  const heads = data?.batches.filter(b => b.head).length ?? 0
  return (
    <section className="mt-5 border-t border-hairline px-3 pt-3 pb-4">
      <div className="flex items-center gap-2 pb-2">
        <span className="text-[11px] font-medium text-faint">Causal DAG</span>
        {data ? (
          <span className="font-mono text-[10.5px] text-faint">
            {plural(data.total, 'batch', 'batches')} · {heads} head{heads === 1 ? '' : 's'} · {micros(data.elapsed_us)}
          </span>
        ) : null}
        <Tip label="Refresh">
          <Button size="icon-xs" variant="ghost" className="ml-auto" onClick={load}>
            <RefreshCw className={cn(loading && 'animate-spin')} />
          </Button>
        </Tip>
      </div>
      {error ? <div className="rounded-lg border border-dashed border-border px-3 py-4 text-center text-[12px] text-muted-foreground">History endpoint unavailable on this server build.</div> : null}
      <ol className="relative">
        {data?.batches.map((b, i) => {
          const st = actorStyle(b.actor_label)
          const last = i === data.batches.length - 1
          return (
            <li key={b.id} className="relative flex gap-3 pb-3">
              {!last ? <span className="absolute top-4 bottom-0 left-[7px] w-px bg-border" /> : null}
              <span className="relative z-10 mt-1 flex size-[15px] shrink-0 items-center justify-center rounded-full border border-border bg-background dark:bg-card">
                {b.head ? <CircleDot className="size-[11px] text-signal" /> : <span className={cn('size-[7px] rounded-full', st.dot)} />}
              </span>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5 text-[12px]">
                  <span className={cn('inline-flex h-[17px] items-center rounded px-1 text-[10px] font-medium', st.chip)}>{st.label}</span>
                  <span className="font-medium tabular">{plural(b.ops, 'op')}</span>
                  {b.head ? <span className="rounded bg-signal-soft px-1 text-[10px] font-medium text-signal-foreground">head</span> : null}
                  {b.parents > 1 ? <span className="rounded bg-violet-soft px-1 text-[10px] font-medium text-violet">merge ×{b.parents}</span> : null}
                  <span className="ml-auto text-[10.5px] text-faint">{ago(b.wall_ms)}</span>
                </div>
                <div className="mt-0.5 flex items-center gap-1.5 font-mono text-[10.5px] text-faint">
                  <GitCommitHorizontal className="size-3" />
                  {shortId(b.actor, 6)}:{b.start}
                  <span>·</span>
                  lamport {b.start}–{b.end}
                </div>
              </div>
            </li>
          )
        })}
      </ol>
    </section>
  )
}
