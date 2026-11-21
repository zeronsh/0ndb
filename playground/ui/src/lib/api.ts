import type { SpliceOp, TextSplice } from './splices'
import { mailboxDrainPath } from './v2'

export type { SpliceOp, TextSplice }

export type ProviderSlug =
  | 'mock'
  | 'antigravity'
  | 'claude-code'
  | 'codex'
  | 'pi'
  | 'hermes'
  | 'opencode'
  | 'cursor'
  | 'devin'
  | 'muse'

export interface ProviderInfo {
  slug: ProviderSlug
  name: string
  binary: string
  available: boolean
  native_steer: boolean
  persistent: boolean
  resume_session: boolean
  fork_at_message: boolean
}

export interface Info {
  workspace_root: string
  history_id: string
  heads: number
  batches: number
  rss_kb: number
  relay_port: number
  default_access?: string
  page_size?: number
  threads?: number
  dag_batches?: number
  ui_dist?: string | null
  providers: ProviderInfo[]
}

export interface ModelInfo {
  id: string
  name: string
  is_default: boolean
}

export interface Catalog {
  provider: ProviderSlug
  available: boolean
  ready: boolean
  elapsed_us: number
  note: string | null
  models: ModelInfo[]
}

export type SessionStatus = 'idle' | 'running' | 'queued' | 'steering' | 'failed' | string

export interface Session {
  thread_id: string
  worktree_id?: string | null
  title: string
  provider: ProviderSlug
  model: string | null
  status: SessionStatus
  queued_count: number
  message_count: number
  updated_ms: number
  head_page: string | null
}

export interface WorktreeInfo {
  id: string
  title: string
  path: string
  vcs_kind: string
  repo_root: string | null
  ref_name: string | null
  history_id: string
  created: boolean
  is_primary: boolean
  created_ms: number
  source_id: string | null
  conflicts: number
}

export interface WorktreeConflict {
  path: string
  kind: string
  ours: string | null
  theirs: string | null
}

export interface WorktreeSyncResult {
  brought: number
  merged: string[]
  conflicts: { path: string; kind: string }[]
}

export interface WorktreeLandResult {
  landed: number
  brought: number
}

export interface TraceReasoning {
  id: number
  text: string
  started_ms: number
  ended_ms: number | null
}

export interface TraceTool {
  id: string
  name: string
  input: string
  output: string
  is_error: boolean
  started_ms: number
  ended_ms: number | null
}

export interface TraceSteer {
  mode: 'native' | 'fallback'
  prompt: string
  at_ms: number
}

export interface Trace {
  started_ms: number
  ended_ms: number | null
  reasoning: TraceReasoning[]
  tools: TraceTool[]
  steers: TraceSteer[]
  usage: { input_tokens: number; output_tokens: number } | null
  error: string | null
}

export type Role = 'user' | 'assistant' | 'system' | 'steer'
export type MessageStatus = 'pending' | 'running' | 'completed' | 'interrupted' | 'failed'

export interface Message {
  msg_id: string
  parent_id: string | null
  role: Role
  status: MessageStatus
  provider: ProviderSlug
  model: string | null
  created_ms: number
  updated_ms?: number
  content: string
  steer_of?: string | null
  switched_from?: string | null
  siblings: string[]
  sibling_index?: number
  trace?: Trace | null
}

export interface Page {
  messages: Message[]
  has_more: boolean
  elapsed_us: number
  next_before: string | null
  head_page: string | null
}

export interface QueueItem {
  item_id: string
  kind: 'steer' | 'follow_up'
  status: 'pending' | 'dispatching' | 'injected' | 'completed' | 'cancelled'
  provider: ProviderSlug
  prompt: string
  model?: string | null
  created_ms?: number
  updated_ms?: number
}

export interface FileEntry {
  path: string
  bytes: number
  lines?: number
  changed_ms?: number
  kind?: 'added' | 'modified' | 'seed'
}

export interface FileChange {
  path: string
  kind: 'added' | 'modified' | 'removed'
  bytes: number
  lines: number
  added: number
  removed: number
  splices?: TextSplice[]
}

export interface WriteFileResult {
  ok: boolean
  version: string
  merged: boolean
  content: string
}

export interface RebaseResult {
  ok: boolean
  reload?: boolean
  version?: string
  cursor_start?: number
  cursor_end?: number
  added?: number
  removed?: number
  splices?: TextSplice[]
}

export interface BlameLine {
  line_no: number
  actor: string
  ts: number
  text: string
  wall_ms?: number
  actor_label?: string
}

export interface DiffFile {
  path: string
  status: 'added' | 'removed' | 'modified'
  before: string | null
  after: string | null
}

export interface HistoryBatch {
  id: string
  actor: string
  actor_label: string
  start: number
  end: number
  ops: number
  wall_ms: number
  parents: number
  head: boolean
}

export interface RemotePage {
  page_id: string
  cache_hit: boolean
  elapsed_us: number
  prev_page: string | null
  messages: Message[]
}

export class ApiError extends Error {}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const method = (init?.method ?? 'GET').toUpperCase()
  const isMutation = method !== 'GET' && method !== 'HEAD'
  const res = await fetch(path, {
    ...init,
    headers: isMutation || init?.body ? { 'Content-Type': 'application/json' } : undefined,
  })
  const text = await res.text()
  let data: unknown = null
  try {
    data = text ? JSON.parse(text) : null
  } catch {
    throw new ApiError(text.slice(0, 200) || `${res.status} ${res.statusText}`)
  }
  if (!res.ok || (data && typeof data === 'object' && 'error' in data && Object.keys(data).length === 1)) {
    const err = (data as { error?: string })?.error ?? `${res.status} ${res.statusText}`
    throw new ApiError(humanizeError(err))
  }
  return data as T
}

function humanizeError(code: string) {
  return code.replace(/([a-z])([A-Z])/g, '$1 $2')
}

const post = <T>(path: string, body: unknown = {}) => request<T>(path, { method: 'POST', body: JSON.stringify(body) })
const put = <T>(path: string, body: unknown = {}) => request<T>(path, { method: 'PUT', body: JSON.stringify(body) })
const del = <T>(path: string) => request<T>(path, { method: 'DELETE' })
const q = encodeURIComponent

export const api = {
  info: () => request<Info>('/api/info'),
  models: (provider: string, refresh = false) =>
    refresh ? post<Catalog>('/api/models/refresh', { provider }) : request<Catalog>(`/api/models?provider=${q(provider)}`),
  allModels: () => request<{ catalogs: Partial<Record<ProviderSlug, Catalog>> }>('/api/models/all'),
  sessions: () => request<{ sessions: Session[] }>('/api/sessions'),
  createThread: (title: string, provider: string, model: string | null, worktreeId?: string | null) =>
    post<{ thread_id: string }>('/api/threads', {
      title,
      provider,
      model: model ?? '',
      ...(worktreeId ? { worktree_id: worktreeId } : {}),
    }),
  config: (tid: string, body: { provider?: string; model?: string | null; title?: string }) => post<{ ok: boolean }>(`/api/threads/${tid}/config`, body),
  page: (tid: string, limit: number, before?: string | null) => request<Page>(`/api/threads/${tid}/page?limit=${limit}${before ? `&before=${before}` : ''}`),
  branchPreview: (tid: string, branchMsgId: string, limit: number, fromMsgId?: string) =>
    request<Page>(`/api/threads/${tid}/page?limit=${limit}&branch=${branchMsgId}${fromMsgId ? `&from_msg_id=${fromMsgId}` : ''}`),
  queue: (tid: string) => request<{ items: QueueItem[] }>(`/api/threads/${tid}/queue`),
  send: (tid: string, prompt: string, provider: string, model: string | null) => post<{ ok: boolean }>(`/api/threads/${tid}/send`, { prompt, provider, model: model ?? '' }),
  steer: (tid: string, prompt: string, provider: string, model: string | null) => post<{ item_id: string }>(`/api/threads/${tid}/steer`, { prompt, provider, model: model ?? '' }),
  enqueue: (tid: string, prompt: string, provider: string, model: string | null) => post<{ item_id: string }>(`/api/threads/${tid}/queue`, { prompt, provider, model: model ?? '' }),
  interruptThread: (tid: string) => post<{ interrupted: boolean }>(`/api/threads/${tid}/interrupt`),
  drain: (tid: string) => post<{ ok: boolean }>(`/api/threads/${tid}/drain`),
  edit: (tid: string, msgId: string, prompt: string, provider: string, model: string | null) => post<{ msg_id: string }>(`/api/threads/${tid}/edit`, { msg_id: msgId, prompt, provider, model: model ?? '' }),
  rollback: (tid: string, msgId: string | null, limit?: number) => post<{ ok: boolean; elapsed_us: number; page: Page }>(`/api/threads/${tid}/rollback`, limit ? { msg_id: msgId ?? '', limit } : { msg_id: msgId ?? '' }),
  branch: (tid: string, msgId: string, limit?: number, fromMsgId?: string) =>
    post<{ leaf_msg_id: string; elapsed_us: number; page: Page }>(`/api/threads/${tid}/branch`, {
      msg_id: msgId,
      ...(limit ? { limit } : {}),
      ...(fromMsgId ? { from_msg_id: fromMsgId } : {}),
    }),
  diff: (tid: string, msgId: string) => request<{ msg_id: string; elapsed_us: number; files: DiffFile[] }>(`/api/threads/${tid}/diff?msg_id=${msgId}`),
  queueEdit: (itemId: string, prompt: string) => post<{ ok: boolean }>(`/api/queue/${itemId}/edit`, { prompt }),
  queueCancel: (itemId: string) => post<{ ok: boolean }>(`/api/queue/${itemId}/cancel`),
  files: () => request<{ version?: string; files: FileEntry[] }>('/api/files'),
  file: (path: string, at?: string, side: 'pre' | 'post' = 'post') =>
    request<{ path: string; version?: string; content: string | null; at?: string }>(`/api/file?path=${q(path)}${at ? `&at=${at}&side=${side}` : ''}`),
  writeFile: (path: string, content: string, baseVersion?: string) =>
    post<WriteFileResult>('/api/file', baseVersion ? { path, content, base_version: baseVersion } : { path, content }),
  saveFileSplices: (path: string, baseVersion: string, splices: SpliceOp[], inserted: string) =>
    post<WriteFileResult>('/api/file', { path, base_version: baseVersion, splices, inserted }),
  rebaseFile: (path: string, baseVersion: string, draft: string, cursorStart: number, cursorEnd: number) =>
    post<RebaseResult>('/api/file/rebase', { path, base_version: baseVersion, draft, cursor_start: cursorStart, cursor_end: cursorEnd }),
  ingest: () => post<{ ingested: boolean }>('/api/ingest'),
  blame: (path: string) => request<{ lines: BlameLine[] }>(`/api/blame?path=${q(path)}`),
  history: (limit = 200) => request<{ elapsed_us: number; total: number; batches: HistoryBatch[] }>(`/api/history?limit=${limit}`),
  worktrees: () => request<{ worktrees: WorktreeInfo[] }>('/api/worktrees'),
  createWorktree: (title: string) => post<{ worktree: WorktreeInfo }>('/api/worktrees', { title }),
  adoptWorktree: (path: string, title: string) => post<{ worktree: WorktreeInfo }>('/api/worktrees/adopt', { path, title }),
  forkWorktree: (id: string, title: string, refName?: string) =>
    post<{ worktree: WorktreeInfo }>(`/api/worktrees/${id}/fork`, refName ? { title, ref_name: refName } : { title }),
  syncWorktree: (id: string) => post<WorktreeSyncResult>(`/api/worktrees/${id}/sync`),
  landWorktree: (id: string) => post<WorktreeLandResult>(`/api/worktrees/${id}/land`),
  worktreeConflicts: (id: string) => request<{ conflicts: WorktreeConflict[] }>(`/api/worktrees/${id}/conflicts`),
  resolveWorktreeConflict: (id: string, path: string, resolution: 'ours' | 'theirs' | 'delete' | 'content', content?: string) =>
    post<{ ok: boolean }>(`/api/worktrees/${id}/resolve`, resolution === 'content' ? { path, resolution, content: content ?? '' } : { path, resolution }),
  removeWorktree: (id: string, force = false, deleteRef = false) =>
    post<{ ok: boolean }>(`/api/worktrees/${id}/remove`, { force, delete_ref: deleteRef }),
  worktreeFiles: (id: string) => request<{ version?: string; files: FileEntry[] }>(`/api/worktrees/${id}/files`),
  worktreeFile: (id: string, path: string) => request<{ path: string; version?: string; content: string | null }>(`/api/worktrees/${id}/file?path=${q(path)}`),
  worktreeHistory: (id: string, limit = 200) => request<{ elapsed_us: number; total: number; batches: HistoryBatch[] }>(`/api/worktrees/${id}/history?limit=${limit}`),
  remoteSessions: () => request<{ elapsed_us: number; last_seq: number; sessions: Session[] }>('/api/remote/sessions'),
  remotePage: (tid: string, pageId: string) => request<RemotePage>(`/api/remote/page?thread_id=${tid}&page_id=${pageId}`),
  remoteClear: () => post<{ ok: boolean }>('/api/remote/clear-cache'),
  remoteTestAuth: () => post<{ rejected: boolean; elapsed_us: number }>('/api/remote/test-auth'),
}

export interface FilesChangedEvent {
  type: 'files_changed'
  source: string
  ts_ms: number
  msg_id: string | null
  from_version?: string
  to_version?: string
  changes: FileChange[]
}

export type ServerEvent =
  | { type: 'models_updated'; provider: ProviderSlug }
  | { type: 'session_updated'; thread_id: string; head_page?: string | null }
  | { type: 'turn_completed'; thread_id: string }
  | { type: 'workspace_updated' }
  | { type: 'worktrees_updated' }
  | { type: 'queue_updated'; thread_id: string }
  | { type: 'v2_updated' }
  | { type: 'v2_trigger_fired' }
  | FilesChangedEvent
  | TurnDelta

export interface TurnDelta {
  type: 'turn_delta'
  thread_id: string
  msg_id?: string
  provider: ProviderSlug
  model?: string
  kind: 'turn_started' | 'reasoning_delta' | 'text_delta' | 'tool_started' | 'tool_finished' | 'steer_injected' | 'steer_fallback' | 'usage'
  ts_ms?: number
  parent_id?: string
  text?: string
  block?: number
  tool_id?: string
  name?: string
  input?: string
  is_error?: boolean
  input_tokens?: number
  output_tokens?: number
}

import type {
  V2Budget,
  V2Health,
  V2SlotState,
  V2SpaceAccess,
  V2SpaceBinding,
  V2SpaceKind,
  V2TaskStatus,
} from './v2'

export type {
  V2Budget,
  V2Health,
  V2SlotState,
  V2SpaceAccess,
  V2SpaceBinding,
  V2SpaceKind,
  V2TaskStatus,
}

export interface V2ProjectSpaceRef {
  space_id: string
  alias: string
  kind: V2SpaceKind
  access: V2SpaceAccess
}

export interface V2Project {
  project_id: string
  name: string
  title: string
  instructions: string
  spaces: V2ProjectSpaceRef[]
  created_ms: number
  updated_ms: number
}

export interface V2Space {
  space_id: string
  name: string
  title: string
  kind: V2SpaceKind
  state: V2SlotState
  projection_path: string | null
  origin_space_id: string | null
  git_remote_url: string | null
  head_count: number
  approx_bytes: number
  created_ms: number
  updated_ms: number
}

export interface V2SpaceFileEntry {
  path: string
  name: string
  kind: 'file' | 'dir' | 'symlink'
}

export interface V2SearchHit {
  path: string
  line: number
  snippet: string
}

export interface V2MetaEntry {
  key: string
  value: string
}

export interface V2TimelineEntry {
  batch_id: { ts: number; actor: string }
  wall_ms: number
  total_added: number
  total_removed: number
  files: { path: string; kind: string; added_lines: number; removed_lines: number }[]
}

export interface V2CheckpointEntry {
  space_id: string
  heads: number
  vcs_ref: string | null
  vcs_rev: string | null
}

export interface V2Thread {
  thread_id: string
  root_thread_id: string
  project_id: string | null
  parent_thread_id: string | null
  task_id: string | null
  active_turn_id: string | null
  depth: number
  title: string
  provider: string
  model: string | null
  status: string
  bindings: V2SpaceBinding[]
  budget: V2Budget
  message_count: number
  active_tasks: number
  unread_mailbox: number
  created_ms: number
  updated_ms: number
}

export interface V2Message {
  msg_id: string
  thread_id: string
  parent_id: string | null
  role: 'user' | 'assistant' | 'system' | 'steer'
  content: string
  provider: string
  status: string
  fencing_epoch: number
  pre_checkpoint: V2CheckpointEntry[]
  post_checkpoint: V2CheckpointEntry[]
  created_ms: number
  updated_ms: number
}

export interface V2Task {
  task_id: string
  parent_thread_id: string
  child_thread_id: string
  title: string
  status: V2TaskStatus
  attempt: number
  join_quorum: number
  depends_on: string[]
  grants: V2SpaceBinding[]
  budget: V2Budget
  err_msg: string | null
  created_ms: number
  updated_ms: number
}

export interface V2MailboxItem {
  item_id: string
  from_thread_id: string
  to_thread_id: string
  task_id: string | null
  kind: 'assign' | 'steer' | 'progress' | 'question' | 'answer' | 'handoff' | 'result' | 'cancel'
  payload: string
  created_ms: number
}

export interface V2Trigger {
  trigger_id: string
  thread_id: string
  kind: 'once' | 'cron' | 'space_changed' | 'mailbox' | 'webhook'
  at_ms?: number
  cron?: string
  space_id?: string
  path_prefix?: string
  debounce_ms?: number
  prompt_template: string
  enabled: boolean
  created_ms: number
}

export interface V2ThreadDetail {
  thread: V2Thread
  messages: V2Message[]
  sealed_pages: { page_id: string; first_msg_id: string; last_msg_id: string; msg_count: number; sealed_ms: number }[]
  tasks: V2Task[]
  mailbox: V2MailboxItem[]
  triggers: V2Trigger[]
  pending_rollback: boolean
  unread_mailbox: number
}

export interface V2LandReport {
  aborted: boolean
  entries: { space_id: string; origin_space_id: string; landed: number; brought: number }[]
  failures: { space_id: string; reason: string; detail: string | null }[]
}

export const apiV2 = {
  health: () => request<V2Health>('/api/v2/health'),
  projects: () => request<{ projects: V2Project[] }>('/api/v2/projects'),
  createProject: (name: string, spaceIds: string[] = []) =>
    post<{ project: V2Project }>('/api/v2/projects', { name, space_ids: spaceIds }),
  addProjectSpace: (projectId: string, spaceId: string, role?: string) =>
    post<{ ok: boolean; project: V2Project }>(`/api/v2/projects/${projectId}/spaces`, { space_id: spaceId, ...(role ? { role } : {}) }),
  removeProjectSpace: (projectId: string, spaceId: string) =>
    del<{ ok: boolean; removed: boolean }>(`/api/v2/projects/${projectId}/spaces/${spaceId}`),
  forkProject: (projectId: string, titlePrefix = 'fork') =>
    post<{ project_id: string; fork_project_id: string; project?: V2Project; forked_space_ids: string[] }>(`/api/v2/projects/${projectId}/fork`, { title_prefix: titlePrefix }),
  syncProject: (projectId: string, forkIds?: string[]) =>
    post<{ synced: { space_id: string; origin_space_id: string; brought: number; merged_count: number; conflict_count: number }[] }>(
      `/api/v2/projects/${projectId}/sync`,
      forkIds ? { fork_ids: forkIds } : {},
    ),
  landProject: (projectId: string, forkIds?: string[]) =>
    post<V2LandReport>(`/api/v2/projects/${projectId}/land`, forkIds ? { fork_ids: forkIds } : {}),

  spaces: () => request<{ spaces: V2Space[] }>('/api/v2/spaces'),
  createSpace: (name: string, kind: V2SpaceKind = 'virtual', path?: string) =>
    post<{ space: V2Space }>('/api/v2/spaces', kind === 'virtual' ? { name, kind } : { name, kind, path }),
  forkSpace: (spaceId: string, name?: string) =>
    post<{ space: V2Space }>(`/api/v2/spaces/${spaceId}/fork`, name ? { name } : {}),
  hibernateSpace: (spaceId: string) =>
    post<{ ok: boolean; hibernated: boolean; state: V2SlotState }>(`/api/v2/spaces/${spaceId}/hibernate`, {}),
  compactSpace: (spaceId: string) =>
    post<{ ok: boolean; pruned_batches: number; reclaimed_batch_bytes: number; removed_blobs: number }>(
      `/api/v2/spaces/${spaceId}/compact`,
      {},
    ),
  spaceFiles: (spaceId: string, dir?: string) =>
    request<{ space_id: string; dir: string; files: V2SpaceFileEntry[] }>(
      `/api/v2/spaces/${spaceId}/files${dir ? `?dir=${q(dir)}` : ''}`,
    ),
  spaceFile: (spaceId: string, path: string) =>
    request<{ space_id: string; path: string; exists: boolean; content: string | null }>(
      `/api/v2/spaces/${spaceId}/file?path=${q(path)}`,
    ),
  writeSpaceFile: (spaceId: string, path: string, content: string) =>
    put<{ ok: boolean; space_id: string; path: string }>(`/api/v2/spaces/${spaceId}/file`, { path, content }),
  deleteSpaceFile: (spaceId: string, path: string) =>
    del<{ ok: boolean; deleted: boolean }>(`/api/v2/spaces/${spaceId}/file?path=${q(path)}`),
  searchSpace: (spaceId: string, query: string) =>
    request<{ space_id: string; query: string; hits: V2SearchHit[] }>(`/api/v2/spaces/${spaceId}/search?q=${q(query)}`),
  spaceMeta: (spaceId: string, prefix = '') =>
    request<{ space_id: string; prefix: string; entries: V2MetaEntry[] }>(
      `/api/v2/spaces/${spaceId}/meta?prefix=${q(prefix)}`,
    ),
  setSpaceMeta: (spaceId: string, key: string, value: string | null) =>
    put<{ ok: boolean; key: string; value: string | null }>(`/api/v2/spaces/${spaceId}/meta`, { key, value }),
  spaceTimeline: (spaceId: string, limit = 30) =>
    request<{ space_id: string; entries: V2TimelineEntry[] }>(`/api/v2/spaces/${spaceId}/timeline?limit=${limit}`),
  spaceDiff: (spaceId: string) =>
    request<{ space_id: string; diff: string }>(`/api/v2/spaces/${spaceId}/diff`),

  threads: (projectId?: string) =>
    request<{ threads: V2Thread[] }>(`/api/v2/threads${projectId ? `?project_id=${q(projectId)}` : ''}`),
  createThread: (body: {
    title: string
    project_id?: string | null
    bindings?: V2SpaceBinding[]
    provider_id?: string
    model?: string | null
    budget?: Partial<V2Budget>
  }) => post<{ thread: V2Thread }>('/api/v2/threads', body),
  thread: (threadId: string) => request<V2ThreadDetail>(`/api/v2/threads/${threadId}`),
  bindSpace: (threadId: string, spaceId: string, alias: string, access: V2SpaceAccess) =>
    post<{ ok: boolean; thread: V2Thread }>(`/api/v2/threads/${threadId}/bind`, { space_id: spaceId, alias, access }),
  unbindSpace: (threadId: string, spaceId: string) =>
    del<{ ok: boolean; removed: boolean }>(`/api/v2/threads/${threadId}/bind/${spaceId}`),
  runTurn: (
    threadId: string,
    body: { prompt: string; reply?: string; mutations?: { space_id: string; path: string; content: string }[] },
  ) =>
    post<{
      turn_id: string
      user_msg_id: string
      fencing_epoch: number
      assistant_text: string
      pre_checkpoint: V2CheckpointEntry[]
      post_checkpoint: V2CheckpointEntry[]
    }>(`/api/v2/threads/${threadId}/turns`, body),
  rollbackThread: (threadId: string, messageId: string, usePreCheckpoint = false) =>
    post<{ ok: boolean; intent_id: string; spaces_rolled_back: number; completed: boolean }>(
      `/api/v2/threads/${threadId}/rollback`,
      { message_id: messageId, use_pre_checkpoint: usePreCheckpoint },
    ),
  recoverRollbacks: (threadId: string) =>
    post<{ ok: boolean; recovered: boolean }>(`/api/v2/threads/${threadId}/recover-rollbacks`, {}),

  tasks: (threadId: string) => request<{ thread_id: string; tasks: V2Task[] }>(`/api/v2/threads/${threadId}/tasks`),
  spawnSubordinate: (
    threadId: string,
    body: {
      title: string
      prompt?: string
      bindings: V2SpaceBinding[]
      budget?: Partial<V2Budget>
      depends_on?: string[]
      join_quorum?: number
    },
  ) =>
    post<{ task_id: string; child_thread_id: string; status: V2TaskStatus; carved_budget: V2Budget; forked_space_ids: string[] }>(
      `/api/v2/threads/${threadId}/subordinates`,
      body,
    ),
  settleTask: (threadId: string, taskId: string, status: 'completed' | 'failed' | 'canceled', summary = '') =>
    post<{ ok: boolean; task_id: string; status: V2TaskStatus; woken_tasks: number }>(
      `/api/v2/threads/${threadId}/tasks/${taskId}/settle`,
      { status, summary },
    ),
  landTask: (threadId: string, taskId: string) =>
    post<V2LandReport>(`/api/v2/threads/${threadId}/tasks/${taskId}/land`, {}),
  cancelTree: (threadId: string, reason = 'Canceled by operator') =>
    post<{ ok: boolean; canceled_threads: number; canceled_tasks: number; canceled_leases: number }>(
      `/api/v2/threads/${threadId}/cancel-tree`,
      { reason },
    ),

  mailbox: (threadId: string) =>
    request<{ thread_id: string; unread_count: number; items: V2MailboxItem[] }>(
      `/api/v2/threads/${threadId}/mailbox`,
    ),
  drainMailbox: (threadId: string) =>
    post<{ ok: boolean; thread_id: string; drained: boolean; unread_count: number; items: V2MailboxItem[] }>(
      mailboxDrainPath(threadId),
      {},
    ),
  postMailbox: (
    threadId: string,
    body: { action?: 'drain'; kind?: V2MailboxItem['kind']; payload?: string; from_thread_id?: string; task_id?: string },
  ) => post<{ ok: boolean; posted?: boolean; drained?: boolean; item_id?: string }>(`/api/v2/threads/${threadId}/mailbox`, body),

  triggers: (threadId: string) =>
    request<{ thread_id: string; triggers: V2Trigger[] }>(`/api/v2/threads/${threadId}/triggers`),
  createTrigger: (
    threadId: string,
    body: {
      kind: V2Trigger['kind']
      at_ms?: number
      cron?: string
      space_id?: string
      path_prefix?: string
      debounce_ms?: number
      webhook_secret?: string
      prompt_template: string
    },
  ) => post<{ ok: boolean; trigger_id: string }>(`/api/v2/threads/${threadId}/triggers`, body),
  disableTrigger: (threadId: string, triggerId: string) =>
    del<{ ok: boolean; trigger_id: string; enabled: boolean }>(`/api/v2/threads/${threadId}/triggers/${triggerId}`),
  pollTriggers: (threadId: string, nowMs?: number, fire = true) =>
    post<{ now_ms: number; due: { trigger_id: string; event_token: string; prompt: string; outcome: string }[] }>(
      `/api/v2/threads/${threadId}/triggers/poll`,
      { ...(nowMs !== undefined ? { now_ms: nowMs } : {}), fire },
    ),
}
