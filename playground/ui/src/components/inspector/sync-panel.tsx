import { useState } from 'react'
import { ArrowRight, ChevronLeft, CloudDownload, KeyRound, Laptop, Loader2, Lock, Server, ShieldAlert, ShieldCheck, Smartphone, Trash2, Zap } from 'lucide-react'
import { toast } from 'sonner'
import { api, type RemotePage, type Session } from '@/lib/api'
import { micros, shortId } from '@/lib/format'
import { useStore } from '@/lib/store'
import { cn } from '@/lib/utils'
import { HarnessGlyph } from '../harness-glyph'
import { Button } from '../ui/button'
import { Tip } from '../ui/tooltip'

interface Fetch {
  page_id: string
  cache_hit: boolean
  elapsed_us: number
}

export function SyncPanel() {
  const { info, run } = useStore()
  const [catalog, setCatalog] = useState<{ sessions: Session[]; elapsed_us: number; last_seq: number } | null>(null)
  const [pulling, setPulling] = useState(false)
  const [thread, setThread] = useState<Session | null>(null)
  const [pages, setPages] = useState<RemotePage[]>([])
  const [log, setLog] = useState<Fetch[]>([])
  const [fetching, setFetching] = useState(false)
  const [auth, setAuth] = useState<{ rejected: boolean; elapsed_us: number } | null>(null)
  const [authing, setAuthing] = useState(false)

  const pull = async () => {
    setPulling(true)
    const r = await run('Catalog pull failed', () => api.remoteSessions())
    setPulling(false)
    if (r) setCatalog(r)
  }

  const fetchPage = async (s: Session, pageId: string, append: boolean) => {
    setFetching(true)
    const r = await run('Page fetch failed', () => api.remotePage(s.thread_id, pageId))
    setFetching(false)
    if (!r) return
    setLog(l => [{ page_id: r.page_id, cache_hit: r.cache_hit, elapsed_us: r.elapsed_us }, ...l].slice(0, 12))
    setPages(p => (append ? [...p, r] : [r]))
  }

  const open = (s: Session) => {
    setThread(s)
    setPages([])
    if (s.head_page) fetchPage(s, s.head_page, false)
  }

  const clear = async () => {
    const r = await run('Could not clear cache', () => api.remoteClear())
    if (r) {
      toast('Device B cache cleared', { description: 'Next page fetch goes back over the encrypted relay.' })
      setLog([])
    }
  }

  const testAuth = async () => {
    setAuthing(true)
    const r = await run('Auth test failed', () => api.remoteTestAuth())
    setAuthing(false)
    if (r) setAuth(r)
  }

  const lastPage = pages.at(-1)

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto">
      <div className="px-3 pt-3">
        <Topology port={info?.relay_port} />
      </div>
      <div className="grid grid-cols-2 gap-2 px-3 pt-3">
        <Button variant="outline" size="sm" onClick={pull} disabled={pulling}>
          {pulling ? <Loader2 className="animate-spin" /> : <CloudDownload />} Pull catalog
        </Button>
        <Button variant="outline" size="sm" onClick={clear}>
          <Trash2 /> Clear B cache
        </Button>
      </div>

      <div className="px-3 pt-3">
        <div className={cn('overflow-hidden rounded-xl border bg-card transition-colors', auth ? (auth.rejected ? 'border-ok/30' : 'border-destructive/40') : 'border-border')}>
          <div className="flex items-center gap-2.5 px-3 py-2.5">
            <span className={cn('flex size-7 shrink-0 items-center justify-center rounded-lg', auth ? (auth.rejected ? 'bg-ok-soft text-ok' : 'bg-danger-soft text-destructive') : 'bg-muted text-muted-foreground')}>
              {auth ? auth.rejected ? <ShieldCheck className="size-4" /> : <ShieldAlert className="size-4" /> : <KeyRound className="size-4" />}
            </span>
            <div className="min-w-0 flex-1">
              <div className="text-[12.5px] font-medium">Rogue capability token</div>
              <div className="text-[11.5px] text-muted-foreground">
                {auth ? (auth.rejected ? `Relay refused the forged token in ${micros(auth.elapsed_us)}` : 'Relay accepted an invalid token!') : 'Connect with a forged secret and try to subscribe'}
              </div>
            </div>
            <Button size="xs" variant={auth?.rejected ? 'ghost' : 'outline'} onClick={testAuth} disabled={authing}>
              {authing ? <Loader2 className="size-3 animate-spin" /> : null}
              {auth ? 'Again' : 'Attack'}
            </Button>
          </div>
        </div>
      </div>

      {log.length ? (
        <div className="px-3 pt-3">
          <div className="pb-1.5 text-[11px] font-medium text-faint">Device B fetches</div>
          <div className="flex flex-col gap-px overflow-hidden rounded-lg border border-hairline">
            {log.map((f, i) => (
              <div key={i} className="flex h-7 items-center gap-2 bg-card px-2.5 text-[11.5px]">
                {f.cache_hit ? <Zap className="size-3 text-signal" /> : <Lock className="size-3 text-violet" />}
                <span className={cn('font-medium', f.cache_hit ? 'text-signal-foreground' : 'text-violet')}>{f.cache_hit ? '0-RTT cache hit' : 'relay · decrypted'}</span>
                <span className="font-mono text-[10.5px] text-faint">{shortId(f.page_id, 8)}</span>
                <span className="ml-auto font-mono text-[11px] tabular">{micros(f.elapsed_us)}</span>
              </div>
            ))}
          </div>
        </div>
      ) : null}

      <div className="px-3 pt-4 pb-4">
        {thread ? (
          <div className="flex flex-col gap-2 animate-rise">
            <div className="flex items-center gap-2">
              <Button size="icon-xs" variant="ghost" onClick={() => setThread(null)} aria-label="Back">
                <ChevronLeft />
              </Button>
              <HarnessGlyph slug={thread.provider} size="sm" />
              <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium">{thread.title}</span>
              {fetching ? <Loader2 className="size-3.5 animate-spin text-faint" /> : null}
            </div>
            {pages.map((p, pi) => (
              <div key={p.page_id + pi} className="overflow-hidden rounded-xl border border-border bg-card">
                <div className="flex h-8 items-center gap-2 border-b border-hairline bg-muted/40 px-2.5 text-[11px]">
                  <span className="font-medium">Page {pi + 1}</span>
                  <span className="font-mono text-[10.5px] text-faint">{shortId(p.page_id, 10)}</span>
                  <span className={cn('ml-auto rounded px-1 text-[10px] font-medium', p.cache_hit ? 'bg-signal-soft text-signal-foreground' : 'bg-violet-soft text-violet')}>{p.cache_hit ? 'cache' : 'relay'}</span>
                  <span className="font-mono text-[10.5px] tabular">{micros(p.elapsed_us)}</span>
                </div>
                <div className="flex flex-col divide-y divide-hairline">
                  {p.messages.map(m => (
                    <div key={m.msg_id} className="flex gap-2 px-2.5 py-2">
                      <span className={cn('mt-px h-[17px] shrink-0 rounded px-1 text-[10px] leading-[17px] font-medium', m.role === 'user' ? 'bg-secondary text-muted-foreground' : m.role === 'steer' ? 'bg-amber-soft text-amber' : 'bg-signal-soft text-signal-foreground')}>{m.role}</span>
                      <span className="line-clamp-3 text-[12px] leading-snug text-foreground/85">{m.content || '…'}</span>
                    </div>
                  ))}
                </div>
              </div>
            ))}
            {lastPage?.prev_page ? (
              <Button variant="outline" size="sm" onClick={() => fetchPage(thread, lastPage.prev_page!, true)} disabled={fetching}>
                Follow prev_page <span className="font-mono text-[10.5px] text-faint">{shortId(lastPage.prev_page, 8)}</span>
              </Button>
            ) : pages.length ? (
              <div className="py-1 text-center text-[11px] text-faint">Genesis page reached · chain verified by hash</div>
            ) : null}
            {pages.length ? (
              <Button variant="ghost" size="sm" onClick={() => thread.head_page && fetchPage(thread, thread.head_page, false)} disabled={fetching}>
                <Zap /> Refetch head (expect cache hit)
              </Button>
            ) : null}
          </div>
        ) : catalog ? (
          <div className="flex flex-col gap-1">
            <div className="flex items-center pb-1 text-[11px] font-medium text-faint">
              Remote session catalog
              <span className="ml-auto font-mono text-[10.5px]">seq {catalog.last_seq} · {micros(catalog.elapsed_us)}</span>
            </div>
            {catalog.sessions.map(s => (
              <button key={s.thread_id} onClick={() => open(s)} className="group flex items-center gap-2.5 rounded-lg border border-transparent px-2 py-2 text-left transition hover:border-border hover:bg-card">
                <HarnessGlyph slug={s.provider} size="sm" />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[12.5px]">{s.title}</span>
                  <span className="block font-mono text-[10.5px] text-faint">{s.message_count} msgs · head {s.head_page ? shortId(s.head_page, 8) : '—'}</span>
                </span>
                <ArrowRight className="size-3.5 text-faint opacity-0 transition group-hover:opacity-100" />
              </button>
            ))}
          </div>
        ) : (
          <div className="rounded-xl border border-dashed border-border px-4 py-6 text-center">
            <Smartphone className="mx-auto size-5 text-faint" />
            <div className="mt-2 text-[12.5px] font-medium">Device B is empty</div>
            <div className="mt-1 text-[11.5px] leading-relaxed text-muted-foreground">Pull the encrypted session catalog, then open a session to stream its Merkle pages through the blind relay.</div>
          </div>
        )}
      </div>
    </div>
  )
}

function Topology({ port }: { port?: number }) {
  return (
    <div className="relative overflow-hidden rounded-xl border border-border bg-card p-3">
      <div className="pointer-events-none absolute inset-0 opacity-[0.35] [background-image:radial-gradient(var(--border)_1px,transparent_1px)] [background-size:12px_12px]" />
      <div className="relative flex items-center justify-between gap-1">
        <Node icon={<Laptop className="size-4" />} label="Device A" sub="this server" />
        <Wire label="AEGIS-128L" />
        <Node icon={<Server className="size-4" />} label="Relay" sub={port ? `:${port} · blind` : 'blind'} accent />
        <Wire label="E2EE" />
        <Node icon={<Smartphone className="size-4" />} label="Device B" sub="local-first" />
      </div>
      <div className="relative mt-2.5 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-[10.5px] text-muted-foreground">
        <Tip label="Payloads are sealed with AEGIS-128L before leaving Device A">
          <span className="flex items-center gap-1"><Lock className="size-3 text-violet" />ciphertext only</span>
        </Tip>
        <span className="flex items-center gap-1"><KeyRound className="size-3 text-amber" />capability-scoped topics</span>
        <span className="flex items-center gap-1"><Zap className="size-3 text-signal" />0-RTT cached pages</span>
      </div>
    </div>
  )
}

function Node({ icon, label, sub, accent }: { icon: React.ReactNode; label: string; sub: string; accent?: boolean }) {
  return (
    <div className="flex w-[76px] shrink-0 flex-col items-center gap-1 text-center">
      <span className={cn('flex size-9 items-center justify-center rounded-xl border shadow-soft', accent ? 'border-violet/30 bg-violet-soft text-violet' : 'border-border bg-background text-foreground dark:bg-card')}>{icon}</span>
      <span className="text-[11px] font-medium leading-tight">{label}</span>
      <span className="truncate font-mono text-[9.5px] leading-tight text-faint">{sub}</span>
    </div>
  )
}

function Wire({ label }: { label: string }) {
  return (
    <div className="relative -mt-7 flex min-w-0 flex-1 flex-col items-center">
      <span className="mb-1 font-mono text-[9px] text-violet">{label}</span>
      <span className="relative h-px w-full bg-gradient-to-r from-border via-violet/50 to-border">
        <span className="absolute top-1/2 left-0 size-1.5 -translate-y-1/2 rounded-full bg-violet shadow-[0_0_8px_var(--violet)] animate-wire" />
      </span>
    </div>
  )
}
