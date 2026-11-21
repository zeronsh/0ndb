import { useEffect } from 'react'
import { AlertCircle, Check, GitFork, History, Infinity as InfinityIcon, Loader2, RefreshCw, Repeat, Zap } from 'lucide-react'
import { api } from '@/lib/api'
import { defaultModel, loadModels, providerName, readiness, useCatalogs } from '@/lib/catalog'
import { micros } from '@/lib/format'
import { useStore } from '@/lib/store'
import { cn } from '@/lib/utils'
import { HarnessGlyph } from '../harness-glyph'
import { Button } from '../ui/button'
import { Tip } from '../ui/tooltip'

export function HarnessPanel() {
  const { providers, active, run, refreshSessions } = useStore()
  const catalogs = useCatalogs()

  useEffect(() => {
    for (const p of providers) if (p.available) loadModels(p.slug)
  }, [providers])

  const refreshAll = () => {
    for (const p of providers) if (p.available) loadModels(p.slug, true)
  }

  const use = async (slug: string) => {
    if (!active) return
    await run('Could not switch harness', () => api.config(active.thread_id, { provider: slug, model: slug === 'mock' ? 'sim-native-v1' : '' }))
    refreshSessions()
  }

  const ready = providers.filter(p => readiness(p, catalogs[p.slug]) === 'ready').length

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto">
      <div className="flex items-center gap-2 px-3 pt-3 pb-2">
        <span className="text-[11px] font-medium text-faint">Harnesses</span>
        <span className="font-mono text-[10.5px] text-faint">
          {ready}/{providers.length} ready
        </span>
        <Button size="xs" variant="ghost" className="ml-auto" onClick={refreshAll}>
          <RefreshCw className="size-3" /> Rediscover
        </Button>
      </div>
      <div className="flex flex-col gap-2 px-3 pb-4">
        {providers.map(p => {
          const st = catalogs[p.slug]
          const r = readiness(p, st)
          const d = defaultModel(st)
          const on = active?.provider === p.slug
          const native = p.native_steer
          return (
            <div key={p.slug} className={cn('rounded-xl border bg-card p-3 transition-colors', on ? 'border-signal/40 shadow-[0_0_0_3px_color-mix(in_oklab,var(--signal)_8%,transparent)]' : 'border-border', !p.available && 'bg-transparent')}>
              <div className="flex items-center gap-2.5">
                <HarnessGlyph slug={p.slug} size="lg" dim={!p.available} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5">
                    <span className="text-[13px] font-medium">{providerName(p.slug, providers)}</span>
                    {r === 'ready' ? (
                      <span className="inline-flex items-center gap-1 rounded-full bg-ok-soft px-1.5 text-[10px] font-medium text-ok">
                        <span className="size-1 rounded-full bg-ok" /> ready
                      </span>
                    ) : r === 'setup' ? (
                      <span className="rounded-full bg-amber-soft px-1.5 text-[10px] font-medium text-amber">needs setup</span>
                    ) : r === 'checking' ? (
                      <Loader2 className="size-3 animate-spin text-faint" />
                    ) : (
                      <span className="rounded-full bg-muted px-1.5 text-[10px] font-medium text-faint">not installed</span>
                    )}
                  </div>
                  <div className="mt-0.5 flex items-center gap-1.5 font-mono text-[10.5px] text-faint">
                    <span>{p.binary}</span>
                    {st?.catalog ? (
                      <>
                        <span>·</span>
                        <span>{st.catalog.models.length} models</span>
                        <span>·</span>
                        <span>{micros(st.catalog.elapsed_us)}</span>
                      </>
                    ) : null}
                  </div>
                </div>
                {on ? (
                  <span className="flex items-center gap-1 text-[11px] font-medium text-signal-foreground">
                    <Check className="size-3.5" /> in use
                  </span>
                ) : (
                  <Button size="xs" variant="outline" disabled={!p.available || !active} onClick={() => use(p.slug)}>
                    Use
                  </Button>
                )}
              </div>
              <div className="mt-2.5 flex flex-wrap items-center gap-1">
                {p.slug === 'mock' ? (
                  <>
                    <Pill tone="signal" icon={<Zap className="size-3" />}>sim-native-v1</Pill>
                    <Pill tone="amber" icon={<Repeat className="size-3" />}>sim-fallback-v1</Pill>
                  </>
                ) : (
                  <Pill tone={native ? 'signal' : 'amber'} icon={native ? <Zap className="size-3" /> : <Repeat className="size-3" />}>
                    {native ? 'native steer' : 'interrupt & resume'}
                  </Pill>
                )}
                <Cap on={p.persistent} icon={<InfinityIcon className="size-3" />} label="persistent" />
                <Cap on={p.resume_session} icon={<History className="size-3" />} label="resume" />
                <Cap on={p.fork_at_message} icon={<GitFork className="size-3" />} label="fork" />
                {d ? <span className="ml-auto truncate text-[11px] text-muted-foreground">default · {d.name}</span> : null}
              </div>
              {st?.catalog?.note && p.available ? (
                <div className="mt-2 flex gap-1.5 text-[11px] leading-snug text-amber">
                  <AlertCircle className="mt-px size-3 shrink-0" />
                  <span className="text-muted-foreground">{st.catalog.note}</span>
                </div>
              ) : null}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function Pill({ tone, icon, children }: { tone: 'signal' | 'amber'; icon: React.ReactNode; children: React.ReactNode }) {
  return <span className={cn('inline-flex h-5 items-center gap-1 rounded-md px-1.5 text-[10.5px] font-medium', tone === 'signal' ? 'bg-signal-soft text-signal-foreground' : 'bg-amber-soft text-amber')}>{icon}{children}</span>
}

function Cap({ on, icon, label }: { on: boolean; icon: React.ReactNode; label: string }) {
  return (
    <Tip label={`${on ? 'Supports' : 'No'} ${label}`}>
      <span className={cn('inline-flex h-5 items-center gap-1 rounded-md px-1.5 text-[10.5px]', on ? 'bg-muted text-muted-foreground' : 'text-faint/60 line-through')}>
        {icon}
        {label}
      </span>
    </Tip>
  )
}
