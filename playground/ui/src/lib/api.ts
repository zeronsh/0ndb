import type { TextSplice } from './splices'

export type { TextSplice }

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
  title: string
  provider: ProviderSlug
  model: string | null
  status: SessionStatus
  queued_count: number
  message_count: number
  updated_ms: number
  head_page: string | null
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
  const res = await fetch(path, {
    ...init,
    headers: init?.body ? { 'Content-Type': 'application/json' } : undefined,
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
const q = encodeURIComponent

export const api = {
  info: () => request<Info>('/api/info'),
  models: (provider: string, refresh = false) => request<Catalog>(`/api/models?provider=${q(provider)}&refresh=${refresh ? 1 : 0}`),
  allModels: () => request<{ catalogs: Partial<Record<ProviderSlug, Catalog>> }>('/api/models/all'),
  sessions: () => request<{ sessions: Session[] }>('/api/sessions'),
  createThread: (title: string, provider: string, model: string | null) => post<{ thread_id: string }>('/api/threads', { title, provider, model: model ?? '' }),
  config: (tid: string, body: { provider?: string; model?: string | null; title?: string }) => post<{ ok: boolean }>(`/api/threads/${tid}/config`, body),
  page: (tid: string, limit: number, before?: string | null) => request<Page>(`/api/threads/${tid}/page?limit=${limit}${before ? `&before=${before}` : ''}`),
  branchPreview: (tid: string, branchMsgId: string, limit: number, fromMsgId?: string) =>
    request<Page>(`/api/threads/${tid}/page?limit=${limit}&branch=${branchMsgId}${fromMsgId ? `&from_msg_id=${fromMsgId}` : ''}`),
  queue: (tid: string) => request<{ items: QueueItem[] }>(`/api/threads/${tid}/queue`),
  send: (tid: string, prompt: string, provider: string, model: string | null) => post<{ ok: boolean }>(`/api/threads/${tid}/send`, { prompt, provider, model: model ?? '' }),
  steer: (tid: string, prompt: string, provider: string, model: string | null) => post<{ item_id: string }>(`/api/threads/${tid}/steer`, { prompt, provider, model: model ?? '' }),
  enqueue: (tid: string, prompt: string, provider: string, model: string | null) => post<{ item_id: string }>(`/api/threads/${tid}/queue`, { prompt, provider, model: model ?? '' }),
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
  rebaseFile: (path: string, baseVersion: string, draft: string, cursorStart: number, cursorEnd: number) =>
    post<RebaseResult>('/api/file/rebase', { path, base_version: baseVersion, draft, cursor_start: cursorStart, cursor_end: cursorEnd }),
  ingest: () => post<{ ingested: boolean }>('/api/ingest'),
  blame: (path: string) => request<{ lines: BlameLine[] }>(`/api/blame?path=${q(path)}`),
  history: (limit = 200) => request<{ elapsed_us: number; total: number; batches: HistoryBatch[] }>(`/api/history?limit=${limit}`),
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
  | { type: 'queue_updated'; thread_id: string }
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
