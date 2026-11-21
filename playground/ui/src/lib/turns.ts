import type { Message, Trace, TraceSteer, TraceTool } from './api'
import type { LiveTrace } from './store'

export type TurnBlock =
  | { kind: 'reasoning'; key: string; text: string; done: boolean; seconds: number | null }
  | { kind: 'tools'; key: string; tools: TraceTool[] }
  | { kind: 'steer'; key: string; steer: TraceSteer }
  | { kind: 'markdown'; key: string; text: string }
  | { kind: 'error'; key: string; text: string }

export interface Turn {
  id: string
  role: 'user' | 'assistant' | 'steer'
  msg: Message
  text: string
  blocks: TurnBlock[]
  streaming: boolean
  pending: boolean
  elapsed: number | null
  usage: Trace['usage']
}

function blocksOf(trace: Trace | null | undefined, text: string, streaming: boolean, msg: Message): TurnBlock[] {
  const items: { at: number; block: TurnBlock }[] = []
  if (trace) {
    for (const r of trace.reasoning) {
      if (!r.text.trim()) continue
      const done = !streaming || r.ended_ms != null
      const seconds = r.ended_ms && r.started_ms ? Math.max(1, Math.round((r.ended_ms - r.started_ms) / 1000)) : null
      items.push({ at: r.started_ms, block: { kind: 'reasoning', key: `r${r.id}`, text: r.text.trim(), done, seconds } })
    }
    trace.tools.forEach((t, i) => items.push({ at: t.started_ms, block: { kind: 'tools', key: `t${i}`, tools: [t] } }))
    trace.steers.forEach((s, i) => items.push({ at: s.at_ms, block: { kind: 'steer', key: `s${i}`, steer: s } }))
  }
  items.sort((a, b) => a.at - b.at)
  const out: TurnBlock[] = []
  for (const it of items) {
    const last = out.at(-1)
    if (it.block.kind === 'tools' && last?.kind === 'tools') last.tools = [...last.tools, ...it.block.tools]
    else out.push(it.block.kind === 'tools' ? { ...it.block, tools: [...it.block.tools] } : it.block)
  }
  if (text) out.push({ kind: 'markdown', key: 'md', text })
  const rawError = trace?.error ?? (msg.status === 'failed' && msg.content.startsWith('Provider error') ? msg.content : null)
  if (rawError && !(msg.status === 'interrupted' && /^interrupted$/i.test(rawError.trim()))) out.push({ kind: 'error', key: 'err', text: rawError })
  return out
}

export function buildTurns(messages: Message[], live: Record<string, LiveTrace>, threadId: string): Turn[] {
  const known = new Set(messages.map(m => m.msg_id))
  const pendingLive: Message[] = Object.values(live)
    .filter(l => l.thread_id === threadId && (l.ended_ms == null || Date.now() - l.ended_ms < 4000) && !known.has(l.msg_id) && !l.msg_id.startsWith('live:'))
    .sort((a, b) => a.started_ms - b.started_ms)
    .map(l => ({
      msg_id: l.msg_id,
      parent_id: l.parent_id,
      role: 'assistant' as const,
      status: l.ended_ms == null ? ('running' as const) : ('completed' as const),
      provider: l.provider as Message['provider'],
      model: l.model,
      created_ms: l.started_ms,
      content: '',
      siblings: [],
    }))

  return [...messages, ...pendingLive].flatMap<Turn>(m => {
    if (m.role === 'user' || m.role === 'steer') {
      return [{ id: m.msg_id, role: m.role, msg: m, text: m.content, blocks: [], streaming: false, pending: false, elapsed: null, usage: null }]
    }
    if (m.role !== 'assistant') return []
    const lt = live[m.msg_id] ?? (m.status === 'running' ? live[`live:${threadId}`] : undefined)
    const trace = m.trace && (m.status !== 'running' || !lt) ? m.trace : (lt ?? m.trace)
    const streaming = m.status === 'running'
    const text = streaming ? lt?.text || m.content : m.content || lt?.text || ''
    const blocks = blocksOf(trace, text, streaming, m)
    const elapsed = trace?.ended_ms && trace.started_ms ? trace.ended_ms - trace.started_ms : m.updated_ms && !streaming ? m.updated_ms - m.created_ms : null
    return [{ id: m.msg_id, role: 'assistant', msg: m, text, blocks, streaming, pending: streaming && blocks.length === 0, elapsed, usage: trace?.usage ?? null }]
  })
}
