import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, Check, ChevronDown, GitFork, GitMerge, Loader2, Plus, RefreshCw } from 'lucide-react'
import { toast } from 'sonner'
import { api, type WorktreeConflict } from '@/lib/api'
import { useStore } from '@/lib/store'
import { cn } from '@/lib/utils'
import { Button } from './ui/button'
import { Popover, PopoverContent, PopoverTrigger } from './ui/popover'
import { Tip } from './ui/tooltip'

export function ForkBar() {
  const { worktrees, activeWorktree, selectWorktree, refreshWorktrees, refreshInfo, run } = useStore()
  const [menuOpen, setMenuOpen] = useState(false)
  const [conflictsOpen, setConflictsOpen] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [forkTitle, setForkTitle] = useState('')
  const [conflicts, setConflicts] = useState<WorktreeConflict[]>([])
  const [loadingConflicts, setLoadingConflicts] = useState(false)

  const wt = activeWorktree
  const isFork = Boolean(wt?.source_id)
  const conflictCount = wt?.conflicts ?? 0

  const loadConflicts = useCallback(async (id: string) => {
    setLoadingConflicts(true)
    const r = await api.worktreeConflicts(id).catch(() => null)
    setLoadingConflicts(false)
    if (r) setConflicts(r.conflicts)
  }, [])

  useEffect(() => {
    if (conflictsOpen && wt) {
      void loadConflicts(wt.id)
    }
  }, [conflictsOpen, wt, loadConflicts])

  if (!wt && worktrees.length === 0) return null

  const doFork = async () => {
    if (!wt || busy) return
    const label = forkTitle.trim() || `${wt.title} fork`
    setBusy('fork')
    const r = await run('Fork failed', () => api.forkWorktree(wt.id, label))
    setBusy(null)
    if (r) {
      setForkTitle('')
      setMenuOpen(false)
      await refreshWorktrees()
      selectWorktree(r.worktree.id)
      toast.success(`Forked ${r.worktree.title}`)
    }
  }

  const doCreateScratch = async () => {
    if (busy) return
    const label = forkTitle.trim() || `Scratch ${worktrees.length + 1}`
    setBusy('create')
    const r = await run('Create worktree failed', () => api.createWorktree(label))
    setBusy(null)
    if (r) {
      setForkTitle('')
      setMenuOpen(false)
      await refreshWorktrees()
      selectWorktree(r.worktree.id)
      toast.success(`Created ${r.worktree.title}`)
    }
  }

  const doSync = async () => {
    if (!wt || busy) return
    setBusy('sync')
    const r = await run('Sync failed', () => api.syncWorktree(wt.id))
    setBusy(null)
    if (r) {
      await refreshWorktrees()
      refreshInfo()
      if (r.conflicts.length > 0) {
        toast.warning(`Synced with ${r.conflicts.length} conflict${r.conflicts.length === 1 ? '' : 's'}`)
        setConflictsOpen(true)
      } else {
        toast.success(`Synced ${wt.title}`, { description: `${r.brought} batch${r.brought === 1 ? '' : 'es'} brought` })
      }
    }
  }

  const doLand = async () => {
    if (!wt || busy) return
    setBusy('land')
    const r = await run('Land failed', () => api.landWorktree(wt.id))
    setBusy(null)
    if (r) {
      await refreshWorktrees()
      refreshInfo()
      toast.success(`Landed ${wt.title}`, { description: `${r.landed} batch${r.landed === 1 ? '' : 'es'} landed` })
    }
  }

  const doResolve = async (path: string, resolution: 'ours' | 'theirs' | 'delete') => {
    if (!wt || busy) return
    setBusy(`resolve:${path}`)
    const r = await run('Resolve failed', () => api.resolveWorktreeConflict(wt.id, path, resolution))
    setBusy(null)
    if (r?.ok) {
      await refreshWorktrees()
      await loadConflicts(wt.id)
      toast.success(`Resolved ${path} (${resolution})`)
    }
  }

  return (
    <div className="flex items-center gap-1 rounded-xl border border-border bg-background/70 p-1 shadow-sm backdrop-blur-md">
      <Popover open={menuOpen} onOpenChange={setMenuOpen}>
        <PopoverTrigger asChild>
          <button
            type="button"
            className="flex h-8 max-w-44 items-center gap-1.5 rounded-lg px-2 text-[12px] text-muted-foreground transition hover:bg-accent hover:text-foreground"
            aria-label="Switch worktree"
          >
            <GitFork className="size-3.5 shrink-0" />
            <span className="truncate font-medium text-foreground">{wt?.title ?? 'Workspace'}</span>
            {wt?.ref_name ? <span className="hidden truncate font-mono text-[10.5px] opacity-70 sm:inline">{wt.ref_name}</span> : null}
            <ChevronDown className="size-3 shrink-0 opacity-60" />
          </button>
        </PopoverTrigger>
        <PopoverContent align="start" className="w-72 p-0">
          <div className="border-b border-border px-3 py-2 text-[11.5px] font-medium text-muted-foreground">Worktrees</div>
          <div className="max-h-56 overflow-y-auto p-1">
            {worktrees.map(item => (
              <button
                key={item.id}
                type="button"
                onClick={() => {
                  selectWorktree(item.id)
                  setMenuOpen(false)
                }}
                className={cn(
                  'flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[12.5px] transition hover:bg-accent',
                  wt?.id === item.id && 'bg-accent/70 font-medium',
                )}
              >
                <span className="flex size-4 shrink-0 items-center justify-center">
                  {wt?.id === item.id ? <Check className="size-3.5 text-primary" /> : <GitFork className="size-3 text-muted-foreground" />}
                </span>
                <span className="min-w-0 flex-1 truncate">{item.title}</span>
                {item.conflicts > 0 ? (
                  <span className="rounded bg-amber-soft px-1.5 py-0.5 font-mono text-[10px] text-amber">{item.conflicts}</span>
                ) : item.is_primary ? (
                  <span className="font-mono text-[10px] text-muted-foreground">main</span>
                ) : item.source_id ? (
                  <span className="font-mono text-[10px] text-muted-foreground">fork</span>
                ) : null}
              </button>
            ))}
          </div>
          <div className="border-t border-border p-2">
            <input
              value={forkTitle}
              onChange={e => setForkTitle(e.target.value)}
              placeholder="New fork or scratch name…"
              className="h-8 w-full rounded-lg border border-border bg-background px-2.5 text-[12px] outline-none focus:border-ring"
            />
            <div className="mt-2 flex items-center gap-1.5">
              <Button size="xs" className="flex-1" onClick={doFork} disabled={!wt || !!busy}>
                {busy === 'fork' ? <Loader2 className="size-3 animate-spin" /> : <GitFork className="size-3" />}
                Fork current
              </Button>
              <Button size="xs" variant="outline" className="flex-1" onClick={doCreateScratch} disabled={!!busy}>
                {busy === 'create' ? <Loader2 className="size-3 animate-spin" /> : <Plus className="size-3" />}
                New scratch
              </Button>
            </div>
          </div>
        </PopoverContent>
      </Popover>

      {isFork ? (
        <>
          <Tip label="Sync fork from source worktree">
            <Button variant="ghost" size="xs" className="h-8 rounded-lg px-2 text-[11.5px]" onClick={doSync} disabled={!!busy}>
              {busy === 'sync' ? <Loader2 className="size-3 animate-spin" /> : <RefreshCw className="size-3" />}
              <span className="hidden md:inline">Sync</span>
            </Button>
          </Tip>
          <Tip label="Land fork changes into source worktree">
            <Button variant="ghost" size="xs" className="h-8 rounded-lg px-2 text-[11.5px]" onClick={doLand} disabled={!!busy || conflictCount > 0}>
              {busy === 'land' ? <Loader2 className="size-3 animate-spin" /> : <GitMerge className="size-3" />}
              <span className="hidden md:inline">Land</span>
            </Button>
          </Tip>
        </>
      ) : null}

      {conflictCount > 0 ? (
        <Popover open={conflictsOpen} onOpenChange={setConflictsOpen}>
          <PopoverTrigger asChild>
            <button
              type="button"
              className="flex h-8 items-center gap-1 rounded-lg bg-amber-soft px-2 text-[11.5px] font-medium text-amber transition hover:brightness-95"
            >
              <AlertTriangle className="size-3" />
              <span className="font-mono tabular">{conflictCount}</span>
            </button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-80 p-0">
            <div className="border-b border-border px-3 py-2 text-[12px] font-medium">Unresolved conflicts</div>
            <div className="max-h-64 divide-y divide-border overflow-y-auto">
              {loadingConflicts ? (
                <div className="flex items-center gap-2 px-3 py-3 text-[12px] text-muted-foreground">
                  <Loader2 className="size-3 animate-spin" /> Loading conflicts…
                </div>
              ) : conflicts.length === 0 ? (
                <div className="px-3 py-3 text-[12px] text-muted-foreground">No unresolved conflicts.</div>
              ) : (
                conflicts.map(c => (
                  <div key={c.path} className="flex flex-col gap-1.5 px-3 py-2">
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-mono text-[11.5px]">{c.path}</span>
                      <span className="shrink-0 font-mono text-[10px] text-muted-foreground">{c.kind}</span>
                    </div>
                    <div className="flex items-center gap-1">
                      <Button size="xs" variant="outline" onClick={() => doResolve(c.path, 'ours')} disabled={!!busy}>
                        Ours
                      </Button>
                      <Button size="xs" variant="outline" onClick={() => doResolve(c.path, 'theirs')} disabled={!!busy}>
                        Theirs
                      </Button>
                      <Button size="xs" variant="ghost" onClick={() => doResolve(c.path, 'delete')} disabled={!!busy}>
                        Delete
                      </Button>
                    </div>
                  </div>
                ))
              )}
            </div>
          </PopoverContent>
        </Popover>
      ) : null}
    </div>
  )
}
