import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { AlertCircle, Check, ChevronDown, CircleDashed, Download, Loader2, RefreshCw, Search, Zap, Repeat, History, GitFork, Infinity as InfinityIcon } from 'lucide-react'
import type { ProviderInfo } from '@/lib/api'
import { defaultModel, loadModels, modelName, providerName, readiness, useCatalogs, type Readiness } from '@/lib/catalog'
import { micros } from '@/lib/format'
import { cn } from '@/lib/utils'
import { Popover, PopoverContent, PopoverTrigger } from './ui/popover'
import { Kbd } from './ui/kbd'
import { HarnessGlyph } from './harness-glyph'
import { Tip } from './ui/tooltip'

interface Option {
  id: string
  name: string
  hint?: string
  isDefault?: boolean
}

const READY_LABEL: Record<Readiness, string> = {
  ready: 'Ready',
  setup: 'Needs setup',
  missing: 'Not installed',
  checking: 'Checking',
}

function ReadyPill({ r, count }: { r: Readiness; count?: number }) {
  if (r === 'ready')
    return (
      <span className="inline-flex items-center gap-1 text-[10.5px] font-medium text-ok tabular">
        <span className="size-1.5 rounded-full bg-ok" />
        {count ?? ''}
      </span>
    )
  if (r === 'checking') return <Loader2 className="size-3 animate-spin text-faint" />
  if (r === 'setup') return <span className="text-[10.5px] font-medium text-amber">setup</span>
  return <span className="text-[10.5px] text-faint">missing</span>
}

export function ModelPicker({
  providers,
  provider,
  model,
  onChange,
  disabled,
  open: openProp,
  onOpenChange,
  compact,
}: {
  providers: ProviderInfo[]
  provider: string
  model: string | null
  onChange: (provider: string, model: string | null) => void
  disabled?: boolean
  open?: boolean
  onOpenChange?: (o: boolean) => void
  compact?: boolean
}) {
  const [openState, setOpenState] = useState(false)
  const open = openProp ?? openState
  const setOpen = (o: boolean) => {
    setOpenState(o)
    onOpenChange?.(o)
  }
  const [focus, setFocus] = useState(provider)
  const [query, setQuery] = useState('')
  const [cursor, setCursor] = useState(0)
  const search = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const catalogs = useCatalogs()
  const focused = providers.find(p => p.slug === focus)
  const state = catalogs[focus]
  const current = providers.find(p => p.slug === provider)

  useEffect(() => {
    if (provider) loadModels(provider)
  }, [provider])

  useEffect(() => {
    if (!open) return
    setFocus(provider)
    setQuery('')
  }, [open, provider])

  useEffect(() => {
    if (open && focused?.available) loadModels(focus)
  }, [open, focus, focused?.available])

  const options = useMemo<Option[]>(() => {
    const models = state?.catalog?.models ?? []
    const d = models.find(m => m.is_default)
    const all: Option[] = [{ id: '', name: 'Default', hint: d ? d.name : 'harness decides', isDefault: true }, ...models.map(m => ({ id: m.id, name: m.name, hint: m.is_default ? 'default' : undefined }))]
    const q = query.trim().toLowerCase()
    if (!q) return all
    return all.filter(m => m.name.toLowerCase().includes(q) || m.id.toLowerCase().includes(q))
  }, [state, query])

  useEffect(() => {
    if (!open) return
    const idx = focus === provider ? options.findIndex(o => o.id === (model ?? '')) : 0
    setCursor(Math.max(0, idx))
    requestAnimationFrame(() => search.current?.focus())
  }, [open, focus])

  useEffect(() => {
    listRef.current?.querySelector('[data-cursor="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [cursor, open])

  const choose = (o: Option) => {
    onChange(focus, o.id || null)
    setOpen(false)
  }

  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setCursor(c => Math.min(options.length - 1, c + 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setCursor(c => Math.max(0, c - 1))
    } else if (e.key === 'Enter' && options[cursor] && focused?.available) {
      e.preventDefault()
      choose(options[cursor])
    } else if (e.key === 'Tab') {
      e.preventDefault()
      const usable = providers.filter(p => p.available)
      const i = usable.findIndex(p => p.slug === focus)
      const next = usable[(i + (e.shiftKey ? usable.length - 1 : 1)) % usable.length]
      if (next) {
        setFocus(next.slug)
        setQuery('')
      }
    }
  }

  const curState = catalogs[provider]
  const label = modelName(provider, model, curState)
  const curReady = current ? readiness(current, curState) : 'checking'
  const loading = state?.status === 'loading'

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          disabled={disabled}
          className={cn(
            'group inline-flex h-7 max-w-full min-w-0 items-center gap-1.5 rounded-lg border border-transparent pr-1.5 pl-1 text-[12.5px] transition-colors hover:border-border hover:bg-accent data-[state=open]:border-border data-[state=open]:bg-accent disabled:opacity-50',
            compact && 'h-6',
          )}
          aria-label="Choose harness and model"
        >
          <HarnessGlyph slug={provider} size="sm" />
          <span className="truncate font-medium">{providerName(provider, providers)}</span>
          <span className="text-faint">/</span>
          <span className={cn('truncate text-muted-foreground', !model && 'italic')}>{!model ? `Default${defaultModel(curState) ? ` · ${label}` : ''}` : label}</span>
          {curReady === 'setup' || curReady === 'missing' ? <AlertCircle className="size-3 shrink-0 text-amber" /> : null}
          <ChevronDown className="size-3 shrink-0 text-faint transition-transform group-data-[state=open]:rotate-180" />
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-[600px] max-w-[calc(100vw-24px)] overflow-hidden p-0" onKeyDown={onKey} onOpenAutoFocus={e => e.preventDefault()}>
        <div className="flex h-[380px]">
          <div className="flex w-[196px] shrink-0 flex-col border-r border-hairline bg-muted/40 p-1.5 dark:bg-black/10">
            <div className="px-2 pt-1 pb-1.5 text-[11px] font-medium text-faint">Harness</div>
            <div className="flex flex-col gap-px overflow-y-auto scrollbar-none">
              {providers.map(p => {
                const r = readiness(p, catalogs[p.slug])
                const on = p.slug === focus
                return (
                  <button
                    key={p.slug}
                    onMouseEnter={() => p.available && setFocus(p.slug)}
                    onClick={() => setFocus(p.slug)}
                    className={cn(
                      'flex h-8 items-center gap-2 rounded-md px-2 text-left text-[12.5px] transition-colors',
                      on ? 'bg-background text-foreground shadow-[0_0_0_1px_var(--hairline),0_1px_2px_oklch(0_0_0/0.06)] dark:bg-card' : 'text-muted-foreground hover:text-foreground',
                      !p.available && 'opacity-70',
                    )}
                  >
                    <HarnessGlyph slug={p.slug} size="sm" dim={!p.available} />
                    <span className="flex-1 truncate font-medium">{providerName(p.slug, providers)}</span>
                    {p.slug === provider ? <Check className="size-3.5 text-signal" /> : <ReadyPill r={r} count={catalogs[p.slug]?.catalog?.models.length} />}
                  </button>
                )
              })}
            </div>
          </div>
          <div className="flex min-w-0 flex-1 flex-col">
            <div className="flex h-11 shrink-0 items-center gap-2 border-b border-hairline px-3">
              <Search className="size-4 shrink-0 text-faint" />
              <input
                ref={search}
                value={query}
                onChange={e => {
                  setQuery(e.target.value)
                  setCursor(0)
                }}
                disabled={!focused?.available}
                placeholder={`Search ${providerName(focus, providers)} models`}
                className="h-full min-w-0 flex-1 bg-transparent text-[13px] outline-none placeholder:text-faint"
              />
              <Tip label="Ask the harness again">
                <button
                  onClick={() => loadModels(focus, true)}
                  disabled={!focused?.available || loading}
                  className="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition hover:bg-accent hover:text-foreground disabled:opacity-40"
                >
                  <RefreshCw className={cn('size-3.5', loading && 'animate-spin')} />
                </button>
              </Tip>
            </div>
            <div className="flex h-8 shrink-0 items-center gap-2 border-b border-hairline px-3 text-[11px] text-faint">
              <span className="font-mono">{focused?.binary ?? focus}</span>
              <span>·</span>
              <span className={cn(readiness(focused ?? providers[0], state) === 'ready' ? 'text-ok' : readiness(focused ?? providers[0], state) === 'missing' ? '' : 'text-amber')}>
                {focused ? READY_LABEL[readiness(focused, state)] : ''}
              </span>
              {state?.catalog ? (
                <>
                  <span>·</span>
                  <span className="tabular">{state.catalog.models.length} models</span>
                  <span className="ml-auto tabular">discovered in {micros(state.catalog.elapsed_us)}</span>
                </>
              ) : null}
            </div>
            <div ref={listRef} className="min-h-0 flex-1 overflow-y-auto p-1.5">
              {!focused?.available ? (
                <Empty icon={<Download className="size-4" />} title={`${providerName(focus, providers)} isn't installed`}>
                  Put <code className="rounded bg-muted px-1 py-px font-mono text-[11.5px]">{focused?.binary}</code> on your <code className="font-mono text-[11.5px]">PATH</code> and reopen this picker — discovery runs live.
                </Empty>
              ) : state?.status === 'error' ? (
                <Empty icon={<AlertCircle className="size-4 text-destructive" />} title="Discovery failed">
                  {state.error}
                </Empty>
              ) : (
                <>
                  {state?.catalog?.note && !state.catalog.models.length ? (
                    <div className="m-1 mb-2 flex gap-2 rounded-lg border border-amber/25 bg-amber-soft px-2.5 py-2 text-[12px] leading-relaxed text-amber">
                      <AlertCircle className="mt-0.5 size-3.5 shrink-0" />
                      <span className="text-foreground/80">{state.catalog.note}</span>
                    </div>
                  ) : null}
                  {options.map((o, i) => {
                    const selected = focus === provider && o.id === (model ?? '')
                    return (
                      <button
                        key={o.id || '__default'}
                        data-cursor={i === cursor}
                        onMouseMove={() => setCursor(i)}
                        onClick={() => choose(o)}
                        className={cn('flex w-full items-center gap-2.5 rounded-md px-2 py-1.5 text-left transition-colors', i === cursor ? 'bg-accent' : '')}
                      >
                        <span className="flex size-4 shrink-0 items-center justify-center">
                          {selected ? <Check className="size-3.5 text-signal" /> : o.isDefault ? <CircleDashed className="size-3.5 text-faint" /> : null}
                        </span>
                        <span className="flex min-w-0 flex-1 flex-col">
                          <span className="flex items-center gap-1.5 text-[13px]">
                            <span className={cn('truncate', o.isDefault && 'font-medium')}>{o.name}</span>
                            {o.hint === 'default' ? <span className="rounded bg-muted px-1 text-[10px] font-medium text-muted-foreground">default</span> : null}
                            {focus === 'mock' && o.id ? (
                              <span className={cn('rounded px-1 text-[10px] font-medium', o.id === 'sim-fallback-v1' ? 'bg-amber-soft text-amber' : 'bg-signal-soft text-signal-foreground')}>
                                {o.id === 'sim-fallback-v1' ? 'interrupt & resume' : 'native steer'}
                              </span>
                            ) : null}
                          </span>
                          <span className="truncate font-mono text-[10.5px] text-faint">{o.isDefault ? `resolves to ${o.hint}` : o.id}</span>
                        </span>
                      </button>
                    )
                  })}
                  {loading && !state?.catalog?.models.length ? (
                    <div className="flex items-center gap-2 px-3 py-3 text-[12px] text-muted-foreground">
                      <Loader2 className="size-3.5 animate-spin" /> Asking {providerName(focus, providers)} for its models…
                    </div>
                  ) : null}
                  {state?.status === 'ready' && query && options.length === 0 ? <div className="px-3 py-6 text-center text-[12px] text-muted-foreground">No models match “{query}”</div> : null}
                </>
              )}
            </div>
            <div className="flex h-9 shrink-0 items-center gap-1.5 border-t border-hairline px-3">
              {focused ? <Caps p={focused} model={focus === provider ? model : (options[cursor]?.id ?? null)} /> : null}
              <span className="ml-auto flex items-center gap-1 text-[10.5px] text-faint">
                <Kbd>Tab</Kbd> harness <Kbd>↑↓</Kbd> <Kbd>↵</Kbd>
              </span>
            </div>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  )
}

function Caps({ p, model }: { p: ProviderInfo; model: string | null }) {
  const native = p.slug === 'mock' ? model !== 'sim-fallback-v1' : p.native_steer
  return (
    <span className="flex min-w-0 items-center gap-1 overflow-hidden">
      <Tip label={native ? 'Steering is injected into the running turn without restarting it' : 'Steering interrupts the turn and resumes with your directive'}>
        <span className={cn('inline-flex h-5 items-center gap-1 rounded px-1.5 text-[10.5px] font-medium', native ? 'bg-signal-soft text-signal-foreground' : 'bg-amber-soft text-amber')}>
          {native ? <Zap className="size-3" /> : <Repeat className="size-3" />}
          {native ? 'Native steer' : 'Interrupt & resume'}
        </span>
      </Tip>
      {p.persistent ? <CapIcon icon={<InfinityIcon className="size-3" />} label="Persistent process" /> : null}
      {p.resume_session ? <CapIcon icon={<History className="size-3" />} label="Resumes native sessions" /> : null}
      {p.fork_at_message ? <CapIcon icon={<GitFork className="size-3" />} label="Forks at any message" /> : null}
    </span>
  )
}

function CapIcon({ icon, label }: { icon: React.ReactNode; label: string }) {
  return (
    <Tip label={label}>
      <span className="inline-flex size-5 items-center justify-center rounded bg-muted text-muted-foreground">{icon}</span>
    </Tip>
  )
}

function Empty({ icon, title, children }: { icon: React.ReactNode; title: string; children: React.ReactNode }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-2 px-8 text-center">
      <span className="flex size-9 items-center justify-center rounded-xl bg-muted text-muted-foreground">{icon}</span>
      <div className="text-[13px] font-medium">{title}</div>
      <div className="text-[12px] leading-relaxed text-muted-foreground">{children}</div>
    </div>
  )
}
