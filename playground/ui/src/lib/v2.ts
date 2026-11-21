export type V2SpaceKind = 'virtual' | 'dir' | 'git_worktree'
export type V2SlotState = 'cold' | 'warm' | 'hot'
export type V2SpaceAccess = 'read_only' | 'shared_rw' | 'isolated_fork'
export type V2TaskStatus = 'pending' | 'ready' | 'leased' | 'running' | 'completed' | 'failed' | 'canceled'

export interface V2Health {
  ok: boolean
  open_spaces: number
  total_spaces: number
  hot_spaces: number
  warm_spaces: number
  cold_spaces: number
  hibernated_spaces: number
  projects_count: number
  threads_count: number
  memory_governor_bytes: number
  workspace_bytes: number
  blob_bytes: number
  git_delta_bytes: number
  watcher_fds: number
  watch_count: number
  runner_id: string
  device_id: string
}

export interface V2SpaceBinding {
  space_id: string
  alias: string
  access: V2SpaceAccess
  mount_rel?: string | null
}

export interface V2Budget {
  max_tokens: number
  used_tokens: number
  max_cost_microusd: number
  used_cost_microusd: number
  max_wall_ms: number
  used_wall_ms: number
  max_depth: number
  max_children: number
  active_children: number
}

export interface V2ThreadSummaryLike {
  thread_id: string
  parent_thread_id: string | null
  depth: number
  title: string
}

export function canAttenuateAccess(parent: V2SpaceAccess, child: V2SpaceAccess): boolean {
  if (parent === 'shared_rw') return true
  if (parent === 'isolated_fork') return child === 'read_only' || child === 'isolated_fork'
  return child === 'read_only'
}

export function validateSubordinateGrants(
  parentBindings: V2SpaceBinding[],
  requested: V2SpaceBinding[],
): { ok: true } | { ok: false; reason: string } {
  for (const req of requested) {
    const parent = parentBindings.find(b => b.space_id === req.space_id)
    if (!parent) {
      return { ok: false, reason: `Space ${req.alias || req.space_id.slice(0, 8)} is not bound to parent thread` }
    }
    if (!canAttenuateAccess(parent.access, req.access)) {
      return { ok: false, reason: `Cannot escalate ${req.alias || req.space_id.slice(0, 8)} from ${parent.access} to ${req.access}` }
    }
  }
  return { ok: true }
}

export function threadModeLabel(bindings: { space_id: string }[]): string {
  if (bindings.length === 0) return 'Zero-Repo'
  if (bindings.length === 1) return '1 Space'
  return `${bindings.length} Spaces`
}

export function spaceStateBadgeVariant(state: V2SlotState): 'ok' | 'amber' | 'outline' {
  if (state === 'hot') return 'ok'
  if (state === 'warm') return 'amber'
  return 'outline'
}

export function taskStatusBadgeVariant(status: V2TaskStatus): 'ok' | 'danger' | 'amber' | 'violet' | 'outline' {
  if (status === 'completed') return 'ok'
  if (status === 'failed' || status === 'canceled') return 'danger'
  if (status === 'running' || status === 'leased') return 'violet'
  if (status === 'ready') return 'amber'
  return 'outline'
}

export function formatBudgetSummary(budget: V2Budget): string {
  const tok = budget.max_tokens > 0 ? `${budget.used_tokens}/${budget.max_tokens} tok` : `${budget.used_tokens} tok`
  const kids = `${budget.active_children}/${budget.max_children} workers`
  return `${tok} · ${kids} · depth ≤ ${budget.max_depth}`
}

export function summarizeHealth(h: V2Health) {
  return {
    spacesLabel: `${h.hot_spaces} hot · ${h.hibernated_spaces} hibernated`,
    governorKb: Math.round(h.memory_governor_bytes / 1024),
    watcherLabel: `${h.watcher_fds} FDs / ${h.watch_count} watches`,
  }
}

export interface ThreadHierarchyRow<T extends V2ThreadSummaryLike> {
  thread: T
  indent: number
}

export function groupThreadsByHierarchy<T extends V2ThreadSummaryLike>(threads: T[]): ThreadHierarchyRow<T>[] {
  const byId = new Map<string, T>()
  const children = new Map<string, T[]>()
  for (const t of threads) byId.set(t.thread_id, t)
  const roots: T[] = []
  for (const t of threads) {
    if (t.parent_thread_id && byId.has(t.parent_thread_id)) {
      const list = children.get(t.parent_thread_id) ?? []
      list.push(t)
      children.set(t.parent_thread_id, list)
    } else {
      roots.push(t)
    }
  }
  const out: ThreadHierarchyRow<T>[] = []
  const visited = new Set<string>()
  const walk = (node: T, indent: number) => {
    if (visited.has(node.thread_id)) return
    visited.add(node.thread_id)
    out.push({ thread: node, indent })
    for (const ch of children.get(node.thread_id) ?? []) {
      walk(ch, indent + 1)
    }
  }
  for (const r of roots) walk(r, 0)
  for (const t of threads) walk(t, t.depth)
  return out
}

export function mailboxDrainPath(threadId: string): string {
  return `/api/v2/threads/${threadId}/mailbox/drain`
}

export function resolveForkActionProjectId(
  projectId: string,
  projectSpaceIds: readonly string[],
  spaces: readonly { space_id: string; origin_space_id: string | null }[],
  forkByOrigin: Record<string, string>,
): string {
  const spaceById = new Map(spaces.map(s => [s.space_id, s]))
  const hasForkSpace = projectSpaceIds.some(sid => Boolean(spaceById.get(sid)?.origin_space_id))
  if (hasForkSpace) return projectId
  return forkByOrigin[projectId] ?? projectId
}
