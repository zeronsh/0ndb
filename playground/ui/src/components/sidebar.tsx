import { useEffect, useMemo, useState } from 'react'
import { Loader2, Monitor, Moon, Plus, Search, Sun } from 'lucide-react'
import type { Session } from '@/lib/api'
import { providerName } from '@/lib/catalog'
import { bytes } from '@/lib/format'
import { useStore } from '@/lib/store'
import type { ThemePref } from '@/lib/theme'
import { cn } from '@/lib/utils'
import { HarnessGlyph } from './harness-glyph'
import { Button } from './ui/button'
import { Kbd } from './ui/kbd'
import { Tip } from './ui/tooltip'
import { DropdownMenu, DropdownMenuContent, DropdownMenuLabel, DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuTrigger } from './ui/dropdown-menu'

export function Logo({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" className={cn('size-6', className)} aria-hidden>
      <rect width="32" height="32" rx="9" className="fill-foreground" />
      <circle cx="16" cy="16" r="7" fill="none" strokeWidth="2.75" className="stroke-background" />
      <path d="M11.4 20.6 20.6 11.4" strokeWidth="2.75" strokeLinecap="round" className="stroke-primary" />
    </svg>
  )
}

function groupOf(ms: number, now: number) {
  const d = (now - ms) / 86400000
  if (d < 1 && new Date(ms).getDate() === new Date(now).getDate()) return 'Today'
  if (d < 2) return 'Yesterday'
  if (d < 7) return 'This week'
  return 'Older'
}

export function Sidebar({ onSearch, theme, setTheme }: { onSearch: () => void; theme: ThemePref; setTheme: (t: ThemePref) => void }) {
  const { sessions, activeId, select, createSession, active, info, conn, providers } = useStore()
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30000)
    return () => clearInterval(t)
  }, [])
  const [creating, setCreating] = useState(false)
  const newSession = async () => {
    setCreating(true)
    await createSession('New session', active?.provider ?? 'mock', active ? active.model : 'sim-native-v1')
    setCreating(false)
  }
  const ThemeIcon = theme === 'dark' ? Moon : theme === 'light' ? Sun : Monitor
  const installed = providers.filter(p => p.available && p.slug !== 'mock').length
  const groups = useMemo(() => {
    const out: { label: string; items: Session[] }[] = []
    for (const s of sessions) {
      const label = groupOf(s.updated_ms, now)
      const g = out.find(x => x.label === label)
      if (g) g.items.push(s)
      else out.push({ label, items: [s] })
    }
    return out
  }, [sessions, now])

  return (
    <aside className="flex h-full w-[256px] shrink-0 flex-col bg-sidebar">
      <div className="flex flex-row items-center justify-between p-3">
        <div className="flex items-center gap-2">
          <Logo />
          <span className="text-[15px] font-medium tracking-[-0.01em]">
            <span className="font-mono">0</span>ndb
          </span>
          <span className="rounded-md bg-[var(--wash)] px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">playground</span>
        </div>
        <DropdownMenu>
          <Tip label="Theme">
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon" className="size-8 rounded-lg" aria-label="Theme">
                <ThemeIcon className="size-4" />
              </Button>
            </DropdownMenuTrigger>
          </Tip>
          <DropdownMenuContent align="end" className="w-36">
            <DropdownMenuLabel>Appearance</DropdownMenuLabel>
            <DropdownMenuRadioGroup value={theme} onValueChange={v => setTheme(v as ThemePref)}>
              <DropdownMenuRadioItem value="light"><Sun /> Light</DropdownMenuRadioItem>
              <DropdownMenuRadioItem value="dark"><Moon /> Dark</DropdownMenuRadioItem>
              <DropdownMenuRadioItem value="system"><Monitor /> System</DropdownMenuRadioItem>
            </DropdownMenuRadioGroup>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <div className="flex flex-col gap-1 px-2 pb-2">
        <Button className="h-9 justify-start gap-2 rounded-lg px-3" onClick={newSession} disabled={creating}>
          {creating ? <Loader2 className="animate-spin" /> : <Plus className="size-4" />}
          <span className="flex-1 text-left">New Session</span>
          <span className="font-mono text-[10.5px] opacity-70">⌘⇧O</span>
        </Button>
        <button onClick={onSearch} className="flex h-9 items-center gap-2 rounded-lg px-3 text-[13px] text-muted-foreground transition-colors hover:bg-accent hover:text-foreground">
          <Search className="size-4" />
          <span className="flex-1 text-left">Search</span>
          <Kbd>⌘K</Kbd>
        </button>
      </div>
      <div className="fade-y-edges min-h-0 flex-1 overflow-y-auto px-2 pb-2">
        {groups.map(g => (
          <div key={g.label} className="pt-2">
            <div className="px-3 pb-1 text-xs font-medium text-primary/80">{g.label}</div>
            {g.items.map(s => (
              <SessionRow key={s.thread_id} s={s} on={s.thread_id === activeId} onClick={() => select(s.thread_id)} providers={providers} />
            ))}
          </div>
        ))}
        {!sessions.length ? <p className="p-4 text-sm text-muted-foreground/50">No sessions yet.</p> : null}
      </div>
      <div className="p-2">
        <div className="rounded-xl border border-border bg-background/50 p-2.5">
          <div className="grid grid-cols-3 gap-1">
            <Vital label="DAG" value={info?.dag_batches ?? info?.batches ?? 0} hint="CRDT batches in the causal DAG" />
            <Vital label="heads" value={info?.heads ?? 0} hint="Concurrent DAG heads" />
            <Vital label="RSS" value={info ? bytes(info.rss_kb * 1024) : '—'} hint="Resident memory of the Zig server" />
          </div>
          <div className="mt-2 flex items-center gap-2 text-[11px] text-muted-foreground">
            <Tip label={conn === 'live' ? 'Server-sent events connected' : conn === 'connecting' ? 'Connecting to event stream' : 'Disconnected — retrying'}>
              <span className="flex items-center gap-1.5">
                <span className={cn('size-1.5 rounded-full', conn === 'live' ? 'bg-ok' : conn === 'connecting' ? 'animate-pulse bg-amber' : 'bg-destructive')} />
                {conn === 'live' ? 'Live' : conn === 'connecting' ? 'Connecting' : 'Offline'}
              </span>
            </Tip>
            <span className="opacity-50">·</span>
            <span>{installed}/9 harnesses</span>
            <span className="ml-auto font-mono text-[10.5px] opacity-60">relay :{info?.relay_port ?? '—'}</span>
          </div>
        </div>
      </div>
    </aside>
  )
}

function Vital({ label, value, hint }: { label: string; value: string | number; hint: string }) {
  return (
    <Tip label={hint}>
      <div className="px-1">
        <div className="text-[10px] text-muted-foreground">{label}</div>
        <div className="font-mono text-[12px] leading-tight tabular">{value}</div>
      </div>
    </Tip>
  )
}

function SessionRow({ s, on, onClick, providers }: { s: Session; on: boolean; onClick: () => void; providers: ReturnType<typeof useStore>['providers'] }) {
  const running = s.status === 'running' || s.status === 'steering'
  return (
    <Tip side="right" label={`${providerName(s.provider, providers)} · ${s.message_count} msgs${s.queued_count ? ` · ${s.queued_count} queued` : ''}`}>
      <button onClick={onClick} className={cn('flex h-9 w-full items-center gap-2 rounded-lg px-2 text-left text-sm transition-colors', on ? 'bg-accent text-foreground' : 'text-foreground/80 hover:bg-accent')}>
        <HarnessGlyph slug={s.provider} size="sm" />
        <span className="min-w-0 flex-1 truncate">{s.title}</span>
        {s.queued_count ? <span className="rounded bg-amber-soft px-1 font-mono text-[10px] text-amber">{s.queued_count}</span> : null}
        {running ? <Loader2 className="size-4 animate-spin text-muted-foreground" /> : s.status === 'failed' ? <span className="size-1.5 rounded-full bg-destructive" /> : null}
      </button>
    </Tip>
  )
}
