import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Activity,
  Bell,
  Boxes,
  CheckCircle2,
  Clock,
  Cpu,
  Database,
  FileCode2,
  FolderGit2,
  FolderKanban,
  GitFork,
  Inbox,
  Layers,
  MessageSquare,
  PauseCircle,
  Play,
  Plus,
  RefreshCw,
  RotateCcw,
  Search,
  Sparkles,
  Trash2,
  XCircle,
} from 'lucide-react'
import { toast } from 'sonner'
import {
  apiV2,
  type V2Health,
  type V2MetaEntry,
  type V2Project,
  type V2SearchHit,
  type V2Space,
  type V2SpaceAccess,
  type V2SpaceBinding,
  type V2SpaceFileEntry,
  type V2SpaceKind,
  type V2Thread,
  type V2ThreadDetail,
  type V2TimelineEntry,
} from '@/lib/api'
import { bytes } from '@/lib/format'
import { useStore } from '@/lib/store'
import {
  formatBudgetSummary,
  groupThreadsByHierarchy,
  resolveForkActionProjectId,
  spaceStateBadgeVariant,
  summarizeHealth,
  taskStatusBadgeVariant,
  threadModeLabel,
  validateSubordinateGrants,
} from '@/lib/v2'
import { cn } from '@/lib/utils'
import { Badge } from '../ui/badge'
import { Button } from '../ui/button'

type V2Section = 'spaces' | 'threads' | 'captain'

export function V2Workspace() {
  const { v2Tick } = useStore()
  const [section, setSection] = useState<V2Section>('spaces')
  const [health, setHealth] = useState<V2Health | null>(null)
  const [projects, setProjects] = useState<V2Project[]>([])
  const [spaces, setSpaces] = useState<V2Space[]>([])
  const [threads, setThreads] = useState<V2Thread[]>([])
  const [loading, setLoading] = useState(false)

  const [selectedSpaceId, setSelectedSpaceId] = useState<string | null>(null)
  const [spaceFiles, setSpaceFiles] = useState<V2SpaceFileEntry[]>([])
  const [spaceMeta, setSpaceMeta] = useState<V2MetaEntry[]>([])
  const [spaceTimeline, setSpaceTimeline] = useState<V2TimelineEntry[]>([])
  const [spaceDiff, setSpaceDiff] = useState('')
  const [selectedFilePath, setSelectedFilePath] = useState('')
  const [fileContent, setFileContent] = useState('')
  const [newFilePath, setNewFilePath] = useState('notes/inbox.md')
  const [metaKey, setMetaKey] = useState('')
  const [metaVal, setMetaVal] = useState('')
  const [searchQuery, setSearchQuery] = useState('')
  const [searchHits, setSearchHits] = useState<V2SearchHit[]>([])

  const [newSpaceName, setNewSpaceName] = useState('')
  const [newSpaceKind, setNewSpaceKind] = useState<V2SpaceKind>('virtual')
  const [newSpacePath, setNewSpacePath] = useState('')
  const [newProjectName, setNewProjectName] = useState('')
  const [newProjectSpaces, setNewProjectSpaces] = useState<string[]>([])
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null)
  const [forkProjectByOrigin, setForkProjectByOrigin] = useState<Record<string, string>>({})

  const [selectedThreadId, setSelectedThreadId] = useState<string | null>(null)
  const [threadDetail, setThreadDetail] = useState<V2ThreadDetail | null>(null)
  const [newThreadTitle, setNewThreadTitle] = useState('')
  const [newThreadProjectId, setNewThreadProjectId] = useState('')
  const [newThreadBindings, setNewThreadBindings] = useState<V2SpaceBinding[]>([])
  const [turnPrompt, setTurnPrompt] = useState('')
  const [turnReply, setTurnReply] = useState('')
  const [bindSpaceId, setBindSpaceId] = useState('')
  const [bindAccess, setBindAccess] = useState<V2SpaceAccess>('shared_rw')

  const [subTitle, setSubTitle] = useState('')
  const [subPrompt, setSubPrompt] = useState('')
  const [subMaxTokens, setSubMaxTokens] = useState('2000')
  const [subGrants, setSubGrants] = useState<V2SpaceBinding[]>([])
  const [mailboxKind, setMailboxKind] = useState<'progress' | 'question' | 'result' | 'steer'>('progress')
  const [mailboxPayload, setMailboxPayload] = useState('')
  const [triggerKind, setTriggerKind] = useState<'cron' | 'once' | 'space_changed' | 'mailbox'>('cron')
  const [triggerCron, setTriggerCron] = useState('*/15 * * * *')
  const [triggerSpaceId, setTriggerSpaceId] = useState('')
  const [triggerPrompt, setTriggerPrompt] = useState('')

  const refreshAll = useCallback(async () => {
    setLoading(true)
    try {
      const [h, p, s, t] = await Promise.all([
        apiV2.health(),
        apiV2.projects(),
        apiV2.spaces(),
        apiV2.threads(),
      ])
      setHealth(h)
      setProjects(p.projects)
      setSpaces(s.spaces)
      setThreads(t.threads)
      setSelectedSpaceId(cur => cur ?? s.spaces[0]?.space_id ?? null)
      setSelectedThreadId(cur => cur ?? t.threads[0]?.thread_id ?? null)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to load V2 state')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    refreshAll()
  }, [refreshAll])

  const loadSpaceDetails = useCallback(async (sid: string) => {
    try {
      const [fl, mt, tl, df] = await Promise.all([
        apiV2.spaceFiles(sid),
        apiV2.spaceMeta(sid, ''),
        apiV2.spaceTimeline(sid, 20),
        apiV2.spaceDiff(sid),
      ])
      setSpaceFiles(fl.files)
      setSpaceMeta(mt.entries)
      setSpaceTimeline(tl.entries)
      setSpaceDiff(df.diff)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to inspect space')
    }
  }, [])

  useEffect(() => {
    if (selectedSpaceId) loadSpaceDetails(selectedSpaceId)
  }, [selectedSpaceId, loadSpaceDetails])

  const loadThreadDetail = useCallback(async (tid: string) => {
    try {
      const d = await apiV2.thread(tid)
      setThreadDetail(d)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to load thread')
    }
  }, [])

  useEffect(() => {
    if (selectedThreadId) loadThreadDetail(selectedThreadId)
  }, [selectedThreadId, loadThreadDetail])

  useEffect(() => {
    if (v2Tick === 0) return
    void refreshAll()
    if (selectedSpaceId) void loadSpaceDetails(selectedSpaceId)
    if (selectedThreadId) void loadThreadDetail(selectedThreadId)
  }, [v2Tick, refreshAll, selectedSpaceId, loadSpaceDetails, selectedThreadId, loadThreadDetail])

  const selectedSpace = useMemo(
    () => spaces.find(s => s.space_id === selectedSpaceId) ?? null,
    [spaces, selectedSpaceId],
  )

  const hierarchyRows = useMemo(() => groupThreadsByHierarchy(threads), [threads])
  const healthSummary = useMemo(() => (health ? summarizeHealth(health) : null), [health])

  const onCreateSpace = async () => {
    const name = newSpaceName.trim()
    if (!name) return
    try {
      const res = await apiV2.createSpace(name, newSpaceKind, newSpaceKind === 'virtual' ? undefined : newSpacePath.trim())
      setNewSpaceName('')
      setNewSpacePath('')
      setSelectedSpaceId(res.space.space_id)
      toast.success(`Created ${res.space.kind} space "${res.space.name}"`)
      await refreshAll()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Create space failed')
    }
  }

  const onCreateProject = async () => {
    const name = newProjectName.trim()
    if (!name) return
    try {
      await apiV2.createProject(name, newProjectSpaces)
      setNewProjectName('')
      setNewProjectSpaces([])
      toast.success(`Created project "${name}"`)
      await refreshAll()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Create project failed')
    }
  }

  const onOpenFile = async (path: string) => {
    if (!selectedSpaceId) return
    try {
      const res = await apiV2.spaceFile(selectedSpaceId, path)
      setSelectedFilePath(path)
      setNewFilePath(path)
      setFileContent(res.content ?? '')
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Read file failed')
    }
  }

  const onSaveFile = async () => {
    if (!selectedSpaceId || !newFilePath.trim()) return
    try {
      await apiV2.writeSpaceFile(selectedSpaceId, newFilePath.trim(), fileContent)
      setSelectedFilePath(newFilePath.trim())
      toast.success(`Saved ${newFilePath.trim()}`)
      await loadSpaceDetails(selectedSpaceId)
      await refreshAll()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Save file failed')
    }
  }

  const onDeleteFile = async (path: string) => {
    if (!selectedSpaceId) return
    try {
      await apiV2.deleteSpaceFile(selectedSpaceId, path)
      if (selectedFilePath === path) {
        setSelectedFilePath('')
        setFileContent('')
      }
      toast.success(`Deleted ${path}`)
      await loadSpaceDetails(selectedSpaceId)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Delete failed')
    }
  }

  const onSearchSpace = async () => {
    if (!selectedSpaceId || !searchQuery.trim()) return
    try {
      const res = await apiV2.searchSpace(selectedSpaceId, searchQuery.trim())
      setSearchHits(res.hits)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Search failed')
    }
  }

  const onPutMeta = async () => {
    if (!selectedSpaceId || !metaKey.trim()) return
    try {
      await apiV2.setSpaceMeta(selectedSpaceId, metaKey.trim(), metaVal)
      setMetaKey('')
      setMetaVal('')
      await loadSpaceDetails(selectedSpaceId)
      toast.success('Updated metadata key')
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Meta update failed')
    }
  }

  const onCreateThread = async () => {
    const title = newThreadTitle.trim() || (newThreadBindings.length === 0 ? 'Zero-Repo Assistant' : 'Multi-Space Thread')
    try {
      const res = await apiV2.createThread({
        title,
        project_id: newThreadProjectId || null,
        bindings: newThreadBindings,
        budget: { max_tokens: 50000, max_depth: 4, max_children: 16 },
      })
      setNewThreadTitle('')
      setNewThreadBindings([])
      setSelectedThreadId(res.thread.thread_id)
      toast.success(`Created thread "${res.thread.title}"`)
      await refreshAll()
      await loadThreadDetail(res.thread.thread_id)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Create thread failed')
    }
  }

  const onRunTurn = async () => {
    if (!selectedThreadId || !turnPrompt.trim()) return
    try {
      await apiV2.runTurn(selectedThreadId, {
        prompt: turnPrompt.trim(),
        ...(turnReply.trim() ? { reply: turnReply.trim() } : {}),
      })
      setTurnPrompt('')
      setTurnReply('')
      await loadThreadDetail(selectedThreadId)
      await refreshAll()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Turn failed')
    }
  }

  const onRollback = async (msgId: string) => {
    if (!selectedThreadId) return
    try {
      const res = await apiV2.rollbackThread(selectedThreadId, msgId)
      toast.success(`2-phase rollback complete (${res.spaces_rolled_back} spaces rewound)`)
      await loadThreadDetail(selectedThreadId)
      if (selectedSpaceId) await loadSpaceDetails(selectedSpaceId)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Rollback failed')
    }
  }

  const onBindSpace = async () => {
    if (!selectedThreadId || !bindSpaceId) return
    const sp = spaces.find(s => s.space_id === bindSpaceId)
    try {
      await apiV2.bindSpace(selectedThreadId, bindSpaceId, sp?.name ?? 'space', bindAccess)
      setBindSpaceId('')
      await loadThreadDetail(selectedThreadId)
      await refreshAll()
      toast.success('Bound space to thread')
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Bind failed')
    }
  }

  const onSpawnSubordinate = async () => {
    if (!selectedThreadId || !threadDetail) return
    const check = validateSubordinateGrants(threadDetail.thread.bindings, subGrants)
    if (!check.ok) {
      toast.error(check.reason)
      return
    }
    try {
      const res = await apiV2.spawnSubordinate(selectedThreadId, {
        title: subTitle.trim() || 'Subordinate Worker',
        prompt: subPrompt.trim(),
        bindings: subGrants,
        budget: { max_tokens: Number(subMaxTokens) || 2000 },
      })
      setSubTitle('')
      setSubPrompt('')
      setSubGrants([])
      toast.success(`Spawned worker task ${res.task_id.slice(0, 8)} (${res.forked_space_ids.length} forks)`)
      await refreshAll()
      await loadThreadDetail(selectedThreadId)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Spawn subordinate failed')
    }
  }

  const onCreateTrigger = async () => {
    if (!selectedThreadId || !triggerPrompt.trim()) return
    try {
      await apiV2.createTrigger(selectedThreadId, {
        kind: triggerKind,
        ...(triggerKind === 'cron' ? { cron: triggerCron.trim() } : {}),
        ...(triggerKind === 'once' ? { at_ms: Date.now() } : {}),
        ...(triggerKind === 'space_changed' ? { space_id: triggerSpaceId } : {}),
        prompt_template: triggerPrompt.trim(),
      })
      setTriggerPrompt('')
      toast.success(`Registered ${triggerKind} trigger`)
      await loadThreadDetail(selectedThreadId)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Register trigger failed')
    }
  }

  const toggleNewBinding = (sp: V2Space) => {
    setNewThreadBindings(prev => {
      if (prev.some(b => b.space_id === sp.space_id)) {
        return prev.filter(b => b.space_id !== sp.space_id)
      }
      return [...prev, { space_id: sp.space_id, alias: sp.name, access: 'shared_rw' }]
    })
  }

  const toggleSubGrant = (b: V2SpaceBinding, access: V2SpaceAccess) => {
    setSubGrants(prev => {
      const exists = prev.find(x => x.space_id === b.space_id)
      if (exists && exists.access === access) {
        return prev.filter(x => x.space_id !== b.space_id)
      }
      return [...prev.filter(x => x.space_id !== b.space_id), { space_id: b.space_id, alias: b.alias, access }]
    })
  }

  return (
    <div className="flex h-full min-w-0 flex-1 flex-col bg-background">
      <header className="flex flex-wrap items-center gap-3 border-b border-hairline px-5 py-3">
        <div className="flex items-center gap-2">
          <Boxes className="size-4 text-primary" />
          <h1 className="text-[14px] font-medium tracking-[-0.01em]">Spaces &amp; Agents</h1>
          <Badge variant="violet">V2 Engine</Badge>
        </div>
        <div className="flex items-center rounded-lg border border-border bg-muted/40 p-0.5 text-[12px]">
          {(
            [
              ['spaces', 'Spaces & Projects', Database],
              ['threads', 'Threads & Rollback', MessageSquare],
              ['captain', 'Captain & Triggers', Cpu],
            ] as const
          ).map(([id, label, Icon]) => (
            <button
              key={id}
              onClick={() => setSection(id)}
              className={cn(
                'flex items-center gap-1.5 rounded-md px-2.5 py-1 font-medium transition-colors',
                section === id ? 'bg-background text-foreground shadow-xs' : 'text-muted-foreground hover:text-foreground',
              )}
            >
              <Icon className="size-3.5" />
              {label}
            </button>
          ))}
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2 text-[11px] text-muted-foreground">
          {health && healthSummary ? (
            <>
              <Badge variant="mono">
                <Activity className="size-3 text-ok" />
                {healthSummary.spacesLabel}
              </Badge>
              <Badge variant="mono">{health.projects_count} proj · {health.threads_count} threads</Badge>
              <Badge variant="mono">gov {bytes(health.memory_governor_bytes)}</Badge>
              <Badge variant="mono">{healthSummary.watcherLabel}</Badge>
            </>
          ) : null}
          <Button variant="outline" size="sm" className="h-7 gap-1.5 text-[12px]" onClick={refreshAll} disabled={loading}>
            <RefreshCw className={cn('size-3.5', loading && 'animate-spin')} />
            Refresh
          </Button>
        </div>
      </header>

      {section === 'spaces' ? (
        <div className="grid min-h-0 flex-1 grid-cols-1 divide-y divide-hairline lg:grid-cols-[360px_1fr] lg:divide-x lg:divide-y-0">
          <div className="flex min-h-0 flex-col overflow-y-auto p-4 gap-5">
            <section className="space-y-2.5">
              <div className="flex items-center justify-between">
                <h2 className="flex items-center gap-1.5 text-[12px] font-semibold uppercase tracking-wider text-muted-foreground">
                  <FolderKanban className="size-3.5" />
                  Projects ({projects.length})
                </h2>
              </div>
              <div className="rounded-xl border border-border bg-card/50 p-3 space-y-2">
                <div className="flex gap-1.5">
                  <input
                    value={newProjectName}
                    onChange={e => setNewProjectName(e.target.value)}
                    placeholder="New multi-space project..."
                    className="h-8 flex-1 rounded-lg border border-input bg-background px-2.5 text-[12px] outline-none focus:ring-1 focus:ring-ring"
                  />
                  <Button size="sm" className="h-8 px-2.5" onClick={onCreateProject}>
                    <Plus className="size-3.5" />
                  </Button>
                </div>
                {spaces.length > 0 ? (
                  <div className="flex flex-wrap gap-1">
                    {spaces.map(s => {
                      const on = newProjectSpaces.includes(s.space_id)
                      return (
                        <button
                          key={s.space_id}
                          onClick={() =>
                            setNewProjectSpaces(cur =>
                              on ? cur.filter(x => x !== s.space_id) : [...cur, s.space_id],
                            )
                          }
                          className={cn(
                            'rounded-md border px-1.5 py-0.5 text-[11px] transition-colors',
                            on ? 'border-primary bg-primary/10 text-primary' : 'border-border text-muted-foreground hover:text-foreground',
                          )}
                        >
                          {s.name}
                        </button>
                      )
                    })}
                  </div>
                ) : null}
              </div>
              <div className="space-y-2">
                {projects.map(p => {
                  const projectSpaceIds = p.spaces.map(sr => sr.space_id)
                  const isForkProject = projectSpaceIds.some(sid => Boolean(spaces.find(s => s.space_id === sid)?.origin_space_id))
                  const actionProjectId = resolveForkActionProjectId(p.project_id, projectSpaceIds, spaces, forkProjectByOrigin)
                  return (
                  <div
                    key={p.project_id}
                    onClick={() => setSelectedProjectId(p.project_id)}
                    className={cn(
                      'cursor-pointer rounded-xl border p-3 space-y-2 transition-colors',
                      selectedProjectId === p.project_id
                        ? 'border-primary/60 bg-primary/5'
                        : 'border-border bg-card hover:bg-accent/30',
                    )}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate text-[13px] font-medium">{p.name}</span>
                      <div className="flex items-center gap-1">
                        {isForkProject ? <Badge variant="violet">fork</Badge> : null}
                        <Badge variant="mono">{p.spaces.length} spaces</Badge>
                      </div>
                    </div>
                    <div className="flex flex-wrap gap-1">
                      {p.spaces.map(sr => (
                        <Badge key={sr.space_id} variant="outline" className="font-mono text-[10px]">
                          {sr.alias} ({sr.kind})
                        </Badge>
                      ))}
                    </div>
                    <div className="flex gap-1.5" onClick={e => e.stopPropagation()}>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 px-2 text-[11px]"
                        onClick={async () => {
                          try {
                            const r = await apiV2.forkProject(p.project_id, 'fork')
                            if (r.fork_project_id) {
                              setSelectedProjectId(r.fork_project_id)
                              setForkProjectByOrigin(cur => ({ ...cur, [p.project_id]: r.fork_project_id }))
                            }
                            if (r.forked_space_ids[0]) setSelectedSpaceId(r.forked_space_ids[0])
                            toast.success(`Forked ${r.forked_space_ids.length} space(s) into ${r.project?.name ?? 'fork project'}`)
                            await refreshAll()
                          } catch (e) {
                            toast.error(e instanceof Error ? e.message : 'Fork failed')
                          }
                        }}
                      >
                        <GitFork className="size-3" /> Fork Set
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 px-2 text-[11px]"
                        onClick={async () => {
                          try {
                            const r = await apiV2.syncProject(actionProjectId)
                            toast.success(`Synced ${r.synced.length} fork(s)`)
                            await refreshAll()
                          } catch (e) {
                            toast.error(e instanceof Error ? e.message : 'Sync failed')
                          }
                        }}
                      >
                        Sync
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 px-2 text-[11px]"
                        onClick={async () => {
                          try {
                            const r = await apiV2.landProject(actionProjectId)
                            toast.success(r.aborted ? `Aborted (${r.failures.length} issue)` : `Landed ${r.entries.length} space(s)`)
                            await refreshAll()
                          } catch (e) {
                            toast.error(e instanceof Error ? e.message : 'Land failed')
                          }
                        }}
                      >
                        Land
                      </Button>
                    </div>
                  </div>
                  )
                })}
              </div>
            </section>

            <section className="space-y-2.5">
              <h2 className="flex items-center gap-1.5 text-[12px] font-semibold uppercase tracking-wider text-muted-foreground">
                <Layers className="size-3.5" />
                Spaces ({spaces.length})
              </h2>
              <div className="rounded-xl border border-border bg-card/50 p-3 space-y-2">
                <div className="flex gap-1.5">
                  <input
                    value={newSpaceName}
                    onChange={e => setNewSpaceName(e.target.value)}
                    placeholder="Space name (e.g. memory, api)..."
                    className="h-8 flex-1 rounded-lg border border-input bg-background px-2.5 text-[12px] outline-none focus:ring-1 focus:ring-ring"
                  />
                  <select
                    value={newSpaceKind}
                    onChange={e => setNewSpaceKind(e.target.value as V2SpaceKind)}
                    className="h-8 rounded-lg border border-input bg-background px-2 text-[12px]"
                  >
                    <option value="virtual">virtual</option>
                    <option value="dir">dir</option>
                    <option value="git_worktree">git_worktree</option>
                  </select>
                </div>
                {newSpaceKind !== 'virtual' ? (
                  <input
                    value={newSpacePath}
                    onChange={e => setNewSpacePath(e.target.value)}
                    placeholder="/abs/path/to/local/repo"
                    className="h-8 w-full rounded-lg border border-input bg-background px-2.5 font-mono text-[11.5px] outline-none focus:ring-1 focus:ring-ring"
                  />
                ) : null}
                <Button size="sm" className="h-8 w-full gap-1.5 text-[12px]" onClick={onCreateSpace}>
                  <Plus className="size-3.5" />
                  {newSpaceKind === 'virtual' ? 'Create Virtual Space (0 disk files)' : 'Adopt Local Projection'}
                </Button>
              </div>
              <div className="space-y-1.5">
                {spaces.map(s => (
                  <div
                    key={s.space_id}
                    onClick={() => setSelectedSpaceId(s.space_id)}
                    className={cn(
                      'cursor-pointer rounded-xl border p-3 transition-colors',
                      selectedSpaceId === s.space_id
                        ? 'border-primary/60 bg-primary/5'
                        : 'border-border bg-card hover:bg-accent/40',
                    )}
                  >
                    <div className="flex items-center gap-2">
                      {s.kind === 'virtual' ? (
                        <Sparkles className="size-3.5 text-violet" />
                      ) : (
                        <FolderGit2 className="size-3.5 text-signal" />
                      )}
                      <span className="truncate text-[13px] font-medium">{s.name}</span>
                      <Badge variant={spaceStateBadgeVariant(s.state)} className="ml-auto">
                        {s.state}
                      </Badge>
                    </div>
                    <div className="mt-1 flex items-center gap-2 font-mono text-[10.5px] text-muted-foreground">
                      <span>{s.kind}</span>
                      <span>·</span>
                      <span>{s.head_count} heads</span>
                      <span>·</span>
                      <span>{bytes(s.approx_bytes)}</span>
                    </div>
                    {s.projection_path ? (
                      <div className="mt-1 truncate font-mono text-[10.5px] text-muted-foreground/80">
                        {s.projection_path}
                      </div>
                    ) : null}
                    <div className="mt-2 flex gap-1.5" onClick={e => e.stopPropagation()}>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 px-2 text-[11px]"
                        onClick={async () => {
                          try {
                            await apiV2.hibernateSpace(s.space_id)
                            toast.success(`Hibernated ${s.name}`)
                            await refreshAll()
                          } catch (err) {
                            toast.error(err instanceof Error ? err.message : 'Hibernate failed')
                          }
                        }}
                      >
                        <PauseCircle className="size-3" /> Hibernate
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 px-2 text-[11px]"
                        onClick={async () => {
                          try {
                            const r = await apiV2.compactSpace(s.space_id)
                            toast.success(`Compacted (${r.pruned_batches} batches pruned)`)
                            await refreshAll()
                          } catch (err) {
                            toast.error(err instanceof Error ? err.message : 'Compact failed')
                          }
                        }}
                      >
                        Compact
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 px-2 text-[11px]"
                        onClick={async () => {
                          try {
                            const r = await apiV2.forkSpace(s.space_id, `${s.name}-fork`)
                            setSelectedSpaceId(r.space.space_id)
                            toast.success(`Forked ${r.space.name}`)
                            await refreshAll()
                          } catch (err) {
                            toast.error(err instanceof Error ? err.message : 'Fork failed')
                          }
                        }}
                      >
                        <GitFork className="size-3" /> Fork
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          </div>

          <div className="flex min-h-0 flex-col overflow-y-auto p-5 gap-5">
            {selectedSpace ? (
              <>
                <div className="flex flex-wrap items-center justify-between gap-2 border-b border-hairline pb-3">
                  <div>
                    <div className="flex items-center gap-2">
                      <h2 className="text-[15px] font-semibold">{selectedSpace.name}</h2>
                      <Badge variant="mono">{selectedSpace.kind}</Badge>
                      <Badge variant={spaceStateBadgeVariant(selectedSpace.state)}>{selectedSpace.state}</Badge>
                    </div>
                    <p className="font-mono text-[11px] text-muted-foreground">{selectedSpace.space_id}</p>
                  </div>
                  <div className="flex items-center gap-1.5">
                    <input
                      value={searchQuery}
                      onChange={e => setSearchQuery(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && onSearchSpace()}
                      placeholder="Search space text..."
                      className="h-8 w-48 rounded-lg border border-input bg-background px-2.5 text-[12px] outline-none focus:ring-1 focus:ring-ring"
                    />
                    <Button variant="outline" size="sm" className="h-8 gap-1 text-[12px]" onClick={onSearchSpace}>
                      <Search className="size-3.5" /> Search
                    </Button>
                  </div>
                </div>

                {searchHits.length > 0 ? (
                  <div className="rounded-xl border border-border bg-muted/30 p-3 space-y-1.5">
                    <div className="text-[11px] font-medium text-muted-foreground">
                      Search hits ({searchHits.length})
                    </div>
                    {searchHits.map((h, i) => (
                      <button
                        key={`${h.path}-${h.line}-${i}`}
                        onClick={() => onOpenFile(h.path)}
                        className="flex w-full items-center gap-2 rounded-md px-2 py-1 text-left font-mono text-[11.5px] hover:bg-accent"
                      >
                        <span className="text-primary">{h.path}:{h.line}</span>
                        <span className="truncate text-muted-foreground">{h.snippet}</span>
                      </button>
                    ))}
                  </div>
                ) : null}

                <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
                  <div className="rounded-xl border border-border bg-card p-3.5 space-y-3">
                    <div className="flex items-center justify-between">
                      <h3 className="flex items-center gap-1.5 text-[12px] font-semibold">
                        <FileCode2 className="size-3.5 text-primary" />
                        Virtual / CRDT Files ({spaceFiles.length})
                      </h3>
                    </div>
                    <div className="max-h-40 space-y-1 overflow-y-auto">
                      {spaceFiles.map(f => (
                        <div
                          key={f.path}
                          className={cn(
                            'flex items-center justify-between rounded-lg px-2 py-1 text-[12px]',
                            selectedFilePath === f.path ? 'bg-primary/10 text-primary' : 'hover:bg-accent',
                          )}
                        >
                          <button
                            className="flex-1 truncate text-left font-mono text-[11.5px]"
                            onClick={() => f.kind === 'file' && onOpenFile(f.path)}
                          >
                            {f.kind === 'dir' ? `${f.path}/` : f.path}
                          </button>
                          {f.kind === 'file' ? (
                            <button
                              onClick={() => onDeleteFile(f.path)}
                              className="ml-2 text-muted-foreground hover:text-destructive"
                              title="Delete file"
                            >
                              <Trash2 className="size-3" />
                            </button>
                          ) : null}
                        </div>
                      ))}
                      {spaceFiles.length === 0 ? (
                        <p className="text-[12px] text-muted-foreground/70">Empty space — write a file below.</p>
                      ) : null}
                    </div>
                    <div className="space-y-2 border-t border-hairline pt-2.5">
                      <input
                        value={newFilePath}
                        onChange={e => setNewFilePath(e.target.value)}
                        placeholder="path/to/file.md"
                        className="h-8 w-full rounded-lg border border-input bg-background px-2.5 font-mono text-[11.5px]"
                      />
                      <textarea
                        value={fileContent}
                        onChange={e => setFileContent(e.target.value)}
                        rows={5}
                        placeholder="File contents stored directly in CRDT RGA text..."
                        className="w-full rounded-lg border border-input bg-background p-2.5 font-mono text-[11.5px] outline-none focus:ring-1 focus:ring-ring"
                      />
                      <Button size="sm" className="h-8 text-[12px]" onClick={onSaveFile}>
                        Write File to Space
                      </Button>
                    </div>
                  </div>

                  <div className="space-y-4">
                    <div className="rounded-xl border border-border bg-card p-3.5 space-y-2.5">
                      <h3 className="text-[12px] font-semibold">LWW Metadata KV ({spaceMeta.length})</h3>
                      <div className="flex gap-1.5">
                        <input
                          value={metaKey}
                          onChange={e => setMetaKey(e.target.value)}
                          placeholder="key (e.g. user.tz)"
                          className="h-8 flex-1 rounded-lg border border-input bg-background px-2 font-mono text-[11.5px]"
                        />
                        <input
                          value={metaVal}
                          onChange={e => setMetaVal(e.target.value)}
                          placeholder="value"
                          className="h-8 flex-1 rounded-lg border border-input bg-background px-2 font-mono text-[11.5px]"
                        />
                        <Button size="sm" className="h-8 px-2.5" onClick={onPutMeta}>
                          Set
                        </Button>
                      </div>
                      <div className="max-h-36 space-y-1 overflow-y-auto">
                        {spaceMeta.map(m => (
                          <div key={m.key} className="flex items-center justify-between rounded-md bg-muted/40 px-2 py-1 font-mono text-[11px]">
                            <span className="text-primary">{m.key}</span>
                            <span className="truncate pl-2 text-muted-foreground">{m.value}</span>
                          </div>
                        ))}
                        {spaceMeta.length === 0 ? (
                          <p className="text-[11.5px] text-muted-foreground/70">No metadata entries yet.</p>
                        ) : null}
                      </div>
                    </div>

                    <div className="rounded-xl border border-border bg-card p-3.5 space-y-2">
                      <h3 className="flex items-center gap-1.5 text-[12px] font-semibold">
                        <Clock className="size-3.5 text-muted-foreground" />
                        Timeline ({spaceTimeline.length}) &amp; Latest Diff
                      </h3>
                      <div className="max-h-28 space-y-1 overflow-y-auto">
                        {spaceTimeline.map(t => (
                          <div key={`${t.batch_id.ts}-${t.batch_id.actor}`} className="flex items-center justify-between font-mono text-[11px] text-muted-foreground">
                            <span>ts:{t.batch_id.ts} · {t.files.map(f => f.path).join(', ') || 'meta'}</span>
                            <span className="text-ok">+{t.total_added}</span>
                          </div>
                        ))}
                      </div>
                      {spaceDiff ? (
                        <pre className="max-h-32 overflow-auto rounded-lg bg-muted/50 p-2 font-mono text-[10.5px] text-foreground/90">
                          {spaceDiff}
                        </pre>
                      ) : null}
                    </div>
                  </div>
                </div>
              </>
            ) : (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 text-center text-muted-foreground">
                <Sparkles className="size-7 opacity-40" />
                <p className="text-[13px]">Create a virtual or local Space on the left to inspect its CRDT state.</p>
              </div>
            )}
          </div>
        </div>
      ) : null}

      {section === 'threads' ? (
        <div className="grid min-h-0 flex-1 grid-cols-1 divide-y divide-hairline lg:grid-cols-[360px_1fr] lg:divide-x lg:divide-y-0">
          <div className="flex min-h-0 flex-col overflow-y-auto p-4 gap-4">
            <div className="rounded-xl border border-border bg-card/50 p-3 space-y-2.5">
              <div className="text-[12px] font-semibold">New V2 Thread (0..N Spaces)</div>
              <input
                value={newThreadTitle}
                onChange={e => setNewThreadTitle(e.target.value)}
                placeholder="Thread title..."
                className="h-8 w-full rounded-lg border border-input bg-background px-2.5 text-[12px]"
              />
              {projects.length > 0 ? (
                <select
                  value={newThreadProjectId}
                  onChange={e => setNewThreadProjectId(e.target.value)}
                  className="h-8 w-full rounded-lg border border-input bg-background px-2 text-[12px]"
                >
                  <option value="">No project (ad-hoc / zero-repo)</option>
                  {projects.map(p => (
                    <option key={p.project_id} value={p.project_id}>{p.name}</option>
                  ))}
                </select>
              ) : null}
              <div className="space-y-1">
                <div className="text-[11px] text-muted-foreground">
                  Bind Spaces ({newThreadBindings.length === 0 ? '0 selected = Zero-Repo pure chat' : `${newThreadBindings.length} bound`})
                </div>
                <div className="flex flex-wrap gap-1">
                  {spaces.map(sp => {
                    const active = newThreadBindings.some(b => b.space_id === sp.space_id)
                    return (
                      <button
                        key={sp.space_id}
                        onClick={() => toggleNewBinding(sp)}
                        className={cn(
                          'rounded-md border px-2 py-0.5 text-[11px] transition-colors',
                          active ? 'border-primary bg-primary/10 text-primary' : 'border-border text-muted-foreground hover:text-foreground',
                        )}
                      >
                        {sp.name}
                      </button>
                    )
                  })}
                </div>
              </div>
              <Button size="sm" className="h-8 w-full gap-1.5 text-[12px]" onClick={onCreateThread}>
                <Plus className="size-3.5" /> Create Thread
              </Button>
            </div>

            <div className="space-y-1.5">
              {hierarchyRows.map(({ thread: t, indent }) => (
                <div
                  key={t.thread_id}
                  onClick={() => setSelectedThreadId(t.thread_id)}
                  style={{ marginLeft: `${Math.min(indent, 4) * 14}px` }}
                  className={cn(
                    'cursor-pointer rounded-xl border p-3 transition-colors',
                    selectedThreadId === t.thread_id
                      ? 'border-primary/60 bg-primary/5'
                      : 'border-border bg-card hover:bg-accent/40',
                  )}
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="truncate text-[13px] font-medium">{t.title}</span>
                    <Badge variant={t.bindings.length === 0 ? 'violet' : 'outline'}>
                      {threadModeLabel(t.bindings)}
                    </Badge>
                  </div>
                  <div className="mt-1 flex items-center gap-2 font-mono text-[10.5px] text-muted-foreground">
                    <span>{t.message_count} msgs</span>
                    <span>·</span>
                    <span>{t.active_tasks} tasks</span>
                    <span>·</span>
                    <span>{t.unread_mailbox} inbox</span>
                  </div>
                </div>
              ))}
            </div>
          </div>

          <div className="flex min-h-0 flex-col overflow-y-auto p-5 gap-4">
            {threadDetail ? (
              <>
                <div className="flex flex-wrap items-center justify-between gap-2 border-b border-hairline pb-3">
                  <div>
                    <div className="flex items-center gap-2">
                      <h2 className="text-[15px] font-semibold">{threadDetail.thread.title}</h2>
                      <Badge variant={threadDetail.thread.bindings.length === 0 ? 'violet' : 'ok'}>
                        {threadModeLabel(threadDetail.thread.bindings)}
                      </Badge>
                    </div>
                    <p className="font-mono text-[11px] text-muted-foreground">
                      {formatBudgetSummary(threadDetail.thread.budget)}
                    </p>
                  </div>
                  <div className="flex items-center gap-1.5">
                    <select
                      value={bindSpaceId}
                      onChange={e => setBindSpaceId(e.target.value)}
                      className="h-8 rounded-lg border border-input bg-background px-2 text-[12px]"
                    >
                      <option value="">Bind space...</option>
                      {spaces.map(s => (
                        <option key={s.space_id} value={s.space_id}>{s.name} ({s.kind})</option>
                      ))}
                    </select>
                    <select
                      value={bindAccess}
                      onChange={e => setBindAccess(e.target.value as V2SpaceAccess)}
                      className="h-8 rounded-lg border border-input bg-background px-2 text-[12px]"
                    >
                      <option value="shared_rw">shared_rw</option>
                      <option value="isolated_fork">isolated_fork</option>
                      <option value="read_only">read_only</option>
                    </select>
                    <Button size="sm" variant="outline" className="h-8 text-[12px]" onClick={onBindSpace}>
                      Bind
                    </Button>
                  </div>
                </div>

                {threadDetail.thread.bindings.length > 0 ? (
                  <div className="flex flex-wrap gap-1.5">
                    {threadDetail.thread.bindings.map(b => (
                      <Badge key={b.space_id} variant="mono" className="gap-1.5 pr-1">
                        <span>{b.alias}</span>
                        <span className="text-primary">{b.access}</span>
                        <button
                          onClick={async () => {
                            try {
                              await apiV2.unbindSpace(threadDetail.thread.thread_id, b.space_id)
                              await loadThreadDetail(threadDetail.thread.thread_id)
                              await refreshAll()
                            } catch (err) {
                              toast.error(err instanceof Error ? err.message : 'Unbind space failed')
                            }
                          }}
                          className="ml-0.5 text-muted-foreground hover:text-destructive"
                        >
                          ×
                        </button>
                      </Badge>
                    ))}
                  </div>
                ) : null}

                <div className="flex-1 space-y-2.5">
                  {threadDetail.messages.map(m => (
                    <div key={m.msg_id} className="rounded-xl border border-border bg-card p-3 space-y-1.5">
                      <div className="flex items-center justify-between gap-2">
                        <div className="flex items-center gap-2">
                          <Badge variant={m.role === 'user' ? 'default' : 'signal'}>{m.role}</Badge>
                          <span className="font-mono text-[10.5px] text-muted-foreground">
                            epoch {m.fencing_epoch} · {m.post_checkpoint.length} space cp
                          </span>
                        </div>
                        <Button
                          variant="outline"
                          size="sm"
                          className="h-6 gap-1 px-2 text-[11px]"
                          onClick={() => onRollback(m.msg_id)}
                        >
                          <RotateCcw className="size-3" /> Rollback Here
                        </Button>
                      </div>
                      <p className="whitespace-pre-wrap text-[13px]">{m.content}</p>
                    </div>
                  ))}
                  {threadDetail.messages.length === 0 ? (
                    <p className="text-[12.5px] text-muted-foreground">No turns recorded yet. Run a turn below to capture an atomic CheckpointVector.</p>
                  ) : null}
                </div>

                <div className="rounded-xl border border-border bg-card/60 p-3 space-y-2">
                  <div className="grid grid-cols-1 gap-2 md:grid-cols-2">
                    <input
                      value={turnPrompt}
                      onChange={e => setTurnPrompt(e.target.value)}
                      placeholder="User prompt..."
                      className="h-8 rounded-lg border border-input bg-background px-2.5 text-[12px]"
                    />
                    <input
                      value={turnReply}
                      onChange={e => setTurnReply(e.target.value)}
                      placeholder="Optional assistant reply..."
                      className="h-8 rounded-lg border border-input bg-background px-2.5 text-[12px]"
                    />
                  </div>
                  <Button size="sm" className="h-8 gap-1.5 text-[12px]" onClick={onRunTurn}>
                    <Play className="size-3.5" /> Record Turn + Checkpoint
                  </Button>
                </div>
              </>
            ) : (
              <div className="flex flex-1 items-center justify-center text-[13px] text-muted-foreground">
                Select or create a V2 thread to inspect turns and multi-space checkpoints.
              </div>
            )}
          </div>
        </div>
      ) : null}

      {section === 'captain' ? (
        <div className="grid min-h-0 flex-1 grid-cols-1 gap-5 overflow-y-auto p-5 xl:grid-cols-3">
          <section className="rounded-xl border border-border bg-card p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h2 className="flex items-center gap-1.5 text-[13px] font-semibold">
                <Cpu className="size-4 text-primary" />
                Captain &amp; Subordinates
              </h2>
              {threadDetail ? (
                <Button
                  variant="outline"
                  size="sm"
                  className="h-7 gap-1 border-destructive/40 text-[11px] text-destructive hover:bg-danger-soft"
                  onClick={async () => {
                    try {
                      const r = await apiV2.cancelTree(threadDetail.thread.thread_id)
                      toast.success(`Canceled ${r.canceled_tasks} tasks / ${r.canceled_threads} threads`)
                      await loadThreadDetail(threadDetail.thread.thread_id)
                      await refreshAll()
                    } catch (err) {
                      toast.error(err instanceof Error ? err.message : 'Cancel tree failed')
                    }
                  }}
                >
                  <XCircle className="size-3.5" /> Cancel Tree
                </Button>
              ) : null}
            </div>

            <select
              value={selectedThreadId ?? ''}
              onChange={e => setSelectedThreadId(e.target.value || null)}
              className="h-8 w-full rounded-lg border border-input bg-background px-2 text-[12px]"
            >
              <option value="">Select Captain thread...</option>
              {threads.map(t => (
                <option key={t.thread_id} value={t.thread_id}>{t.title} (depth {t.depth})</option>
              ))}
            </select>

            {threadDetail ? (
              <>
                <div className="rounded-lg border border-hairline bg-muted/30 p-3 space-y-2">
                  <div className="text-[11.5px] font-medium">Spawn Subordinate</div>
                  <input
                    value={subTitle}
                    onChange={e => setSubTitle(e.target.value)}
                    placeholder="Worker title..."
                    className="h-8 w-full rounded-lg border border-input bg-background px-2 text-[12px]"
                  />
                  <input
                    value={subPrompt}
                    onChange={e => setSubPrompt(e.target.value)}
                    placeholder="Delegated prompt..."
                    className="h-8 w-full rounded-lg border border-input bg-background px-2 text-[12px]"
                  />
                  <input
                    value={subMaxTokens}
                    onChange={e => setSubMaxTokens(e.target.value)}
                    placeholder="Max tokens"
                    className="h-8 w-full rounded-lg border border-input bg-background px-2 font-mono text-[11.5px]"
                  />
                  {threadDetail.thread.bindings.length > 0 ? (
                    <div className="space-y-1">
                      <div className="text-[10.5px] text-muted-foreground">Attenuated Space Grants</div>
                      {threadDetail.thread.bindings.map(b => {
                        const cur = subGrants.find(g => g.space_id === b.space_id)?.access
                        return (
                          <div key={b.space_id} className="flex items-center justify-between gap-1 text-[11px]">
                            <span className="truncate font-mono">{b.alias} ({b.access})</span>
                            <div className="flex gap-1">
                              {(['read_only', 'isolated_fork', 'shared_rw'] as const).map(acc => (
                                <button
                                  key={acc}
                                  onClick={() => toggleSubGrant(b, acc)}
                                  className={cn(
                                    'rounded border px-1.5 py-0.5 font-mono text-[10px]',
                                    cur === acc ? 'border-primary bg-primary/15 text-primary' : 'border-border text-muted-foreground',
                                  )}
                                >
                                  {acc === 'read_only' ? 'ro' : acc === 'isolated_fork' ? 'fork' : 'rw'}
                                </button>
                              ))}
                            </div>
                          </div>
                        )
                      })}
                    </div>
                  ) : null}
                  <Button size="sm" className="h-8 w-full text-[12px]" onClick={onSpawnSubordinate}>
                    Spawn Subordinate
                  </Button>
                </div>

                <div className="space-y-2">
                  {threadDetail.tasks.map(tk => (
                    <div key={tk.task_id} className="rounded-lg border border-border p-2.5 space-y-2">
                      <div className="flex items-center justify-between gap-2">
                        <span className="truncate text-[12.5px] font-medium">{tk.title}</span>
                        <Badge variant={taskStatusBadgeVariant(tk.status)}>{tk.status}</Badge>
                      </div>
                      <div className="font-mono text-[10.5px] text-muted-foreground">
                        child {tk.child_thread_id.slice(0, 8)} · {formatBudgetSummary(tk.budget)}
                      </div>
                      <div className="flex flex-wrap gap-1.5">
                        <Button
                          variant="outline"
                          size="sm"
                          className="h-6 gap-1 px-2 text-[11px]"
                          onClick={async () => {
                            try {
                              await apiV2.settleTask(threadDetail.thread.thread_id, tk.task_id, 'completed', 'Settled via UI')
                              await loadThreadDetail(threadDetail.thread.thread_id)
                              await refreshAll()
                            } catch (e) {
                              toast.error(e instanceof Error ? e.message : 'Settle failed')
                            }
                          }}
                        >
                          <CheckCircle2 className="size-3" /> Settle
                        </Button>
                        <Button
                          variant="outline"
                          size="sm"
                          className="h-6 gap-1 px-2 text-[11px]"
                          onClick={async () => {
                            try {
                              const r = await apiV2.landTask(threadDetail.thread.thread_id, tk.task_id)
                              toast.success(r.aborted ? 'Land aborted (conflict)' : `Landed ${r.entries.length} fork(s)`)
                              await refreshAll()
                            } catch (e) {
                              toast.error(e instanceof Error ? e.message : 'Land failed')
                            }
                          }}
                        >
                          <GitFork className="size-3" /> Land Forks
                        </Button>
                      </div>
                    </div>
                  ))}
                  {threadDetail.tasks.length === 0 ? (
                    <p className="text-[12px] text-muted-foreground">No subordinate tasks spawned yet.</p>
                  ) : null}
                </div>
              </>
            ) : null}
          </section>

          <section className="rounded-xl border border-border bg-card p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h2 className="flex items-center gap-1.5 text-[13px] font-semibold">
                <Inbox className="size-4 text-primary" />
                Thread Mailbox
                {threadDetail ? <Badge variant="mono">{threadDetail.unread_mailbox} unread</Badge> : null}
              </h2>
              {threadDetail ? (
                <Button
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px]"
                  onClick={async () => {
                    try {
                      await apiV2.drainMailbox(threadDetail.thread.thread_id)
                      toast.success('Drained mailbox')
                      await loadThreadDetail(threadDetail.thread.thread_id)
                    } catch (err) {
                      toast.error(err instanceof Error ? err.message : 'Drain mailbox failed')
                    }
                  }}
                >
                  Drain
                </Button>
              ) : null}
            </div>
            {threadDetail ? (
              <>
                <div className="flex gap-1.5">
                  <select
                    value={mailboxKind}
                    onChange={e => setMailboxKind(e.target.value as 'progress' | 'question' | 'result' | 'steer')}
                    className="h-8 rounded-lg border border-input bg-background px-2 text-[12px]"
                  >
                    <option value="progress">progress</option>
                    <option value="question">question</option>
                    <option value="result">result</option>
                    <option value="steer">steer</option>
                  </select>
                  <input
                    value={mailboxPayload}
                    onChange={e => setMailboxPayload(e.target.value)}
                    placeholder="Post message to inbox..."
                    className="h-8 flex-1 rounded-lg border border-input bg-background px-2 text-[12px]"
                  />
                  <Button
                    size="sm"
                    className="h-8 px-2.5 text-[12px]"
                    onClick={async () => {
                      if (!mailboxPayload.trim()) return
                      try {
                        await apiV2.postMailbox(threadDetail.thread.thread_id, { kind: mailboxKind, payload: mailboxPayload.trim() })
                        setMailboxPayload('')
                        await loadThreadDetail(threadDetail.thread.thread_id)
                      } catch (err) {
                        toast.error(err instanceof Error ? err.message : 'Post mailbox failed')
                      }
                    }}
                  >
                    Post
                  </Button>
                </div>
                <div className="space-y-1.5">
                  {threadDetail.mailbox.map(it => (
                    <div key={it.item_id} className="rounded-lg border border-hairline bg-muted/30 p-2.5 space-y-1">
                      <div className="flex items-center justify-between">
                        <Badge variant="outline">{it.kind}</Badge>
                        <span className="font-mono text-[10px] text-muted-foreground">from {it.from_thread_id.slice(0, 8)}</span>
                      </div>
                      <p className="text-[12px]">{it.payload}</p>
                    </div>
                  ))}
                  {threadDetail.mailbox.length === 0 ? (
                    <p className="text-[12px] text-muted-foreground">Mailbox is empty.</p>
                  ) : null}
                </div>
              </>
            ) : null}
          </section>

          <section className="rounded-xl border border-border bg-card p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h2 className="flex items-center gap-1.5 text-[13px] font-semibold">
                <Bell className="size-4 text-primary" />
                Proactive Triggers (Grok Bot)
              </h2>
              {threadDetail ? (
                <Button
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px]"
                  onClick={async () => {
                    try {
                      const r = await apiV2.pollTriggers(threadDetail.thread.thread_id)
                      toast.success(`Polled: ${r.due.length} due trigger(s)`)
                      await loadThreadDetail(threadDetail.thread.thread_id)
                    } catch (err) {
                      toast.error(err instanceof Error ? err.message : 'Poll triggers failed')
                    }
                  }}
                >
                  Poll Due
                </Button>
              ) : null}
            </div>
            {threadDetail ? (
              <>
                <div className="rounded-lg border border-hairline bg-muted/30 p-3 space-y-2">
                  <div className="flex gap-1.5">
                    <select
                      value={triggerKind}
                      onChange={e => setTriggerKind(e.target.value as 'cron' | 'once' | 'space_changed' | 'mailbox')}
                      className="h-8 rounded-lg border border-input bg-background px-2 text-[12px]"
                    >
                      <option value="cron">cron</option>
                      <option value="once">once</option>
                      <option value="space_changed">space_changed</option>
                      <option value="mailbox">mailbox</option>
                    </select>
                    {triggerKind === 'cron' ? (
                      <input
                        value={triggerCron}
                        onChange={e => setTriggerCron(e.target.value)}
                        placeholder="*/15 * * * *"
                        className="h-8 flex-1 rounded-lg border border-input bg-background px-2 font-mono text-[11.5px]"
                      />
                    ) : null}
                    {triggerKind === 'space_changed' ? (
                      <select
                        value={triggerSpaceId}
                        onChange={e => setTriggerSpaceId(e.target.value)}
                        className="h-8 flex-1 rounded-lg border border-input bg-background px-2 text-[12px]"
                      >
                        <option value="">Watch space...</option>
                        {spaces.map(s => (
                          <option key={s.space_id} value={s.space_id}>{s.name}</option>
                        ))}
                      </select>
                    ) : null}
                  </div>
                  <input
                    value={triggerPrompt}
                    onChange={e => setTriggerPrompt(e.target.value)}
                    placeholder="Proactive wake prompt template..."
                    className="h-8 w-full rounded-lg border border-input bg-background px-2 text-[12px]"
                  />
                  <Button size="sm" className="h-8 w-full text-[12px]" onClick={onCreateTrigger}>
                    Register Trigger
                  </Button>
                </div>
                <div className="space-y-1.5">
                  {threadDetail.triggers.map(tr => (
                    <div key={tr.trigger_id} className="rounded-lg border border-border p-2.5 space-y-1">
                      <div className="flex items-center justify-between gap-2">
                        <div className="flex items-center gap-1.5">
                          <Badge variant={tr.enabled ? 'ok' : 'outline'}>{tr.kind}</Badge>
                          {tr.cron ? <span className="font-mono text-[11px] text-muted-foreground">{tr.cron}</span> : null}
                        </div>
                        {tr.enabled ? (
                          <Button
                            variant="outline"
                            size="sm"
                            className="h-6 px-2 text-[10.5px]"
                            onClick={async () => {
                              try {
                                await apiV2.disableTrigger(threadDetail.thread.thread_id, tr.trigger_id)
                                await loadThreadDetail(threadDetail.thread.thread_id)
                              } catch (err) {
                                toast.error(err instanceof Error ? err.message : 'Disable trigger failed')
                              }
                            }}
                          >
                            Disable
                          </Button>
                        ) : (
                          <Badge variant="outline">disabled</Badge>
                        )}
                      </div>
                      <p className="text-[12px] text-muted-foreground">{tr.prompt_template}</p>
                    </div>
                  ))}
                  {threadDetail.triggers.length === 0 ? (
                    <p className="text-[12px] text-muted-foreground">No triggers configured.</p>
                  ) : null}
                </div>
              </>
            ) : null}
          </section>
        </div>
      ) : null}
    </div>
  )
}
