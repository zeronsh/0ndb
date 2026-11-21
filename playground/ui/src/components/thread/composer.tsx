import { forwardRef, useEffect, useImperativeHandle, useRef, useState, type ReactNode } from 'react'
import { ArrowUp, Check, GitBranch, ListPlus, Loader2, Pencil, Play, Repeat, Square, X, Zap } from 'lucide-react'
import { api, type Message, type ProviderInfo, type QueueItem, type Session } from '@/lib/api'
import { steerMode } from '@/lib/catalog'
import { useStore } from '@/lib/store'
import { cn } from '@/lib/utils'
import { ModelPicker } from '../model-picker'
import { Button } from '../ui/button'
import { Kbd } from '../ui/kbd'
import { Tip } from '../ui/tooltip'

export interface ComposerHandle {
  focus: () => void
  openPicker: () => void
  setText: (t: string) => void
}

interface Props {
  session: Session
  running: boolean
  providers: ProviderInfo[]
  editing: Message | null
  cancelEdit: () => void
  onConfig: (provider: string, model: string | null) => void
  onSubmitted: (kind: 'send' | 'queue' | 'steer' | 'edit') => void
  aboveInput?: ReactNode
}

function Reveal({ show, children }: { show: boolean; children: ReactNode }) {
  return (
    <div className={cn('grid transition-[grid-template-rows,opacity] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)]', show ? 'grid-rows-[1fr] opacity-100' : 'grid-rows-[0fr] opacity-0')}>
      <div className="min-h-0 overflow-hidden" inert={!show}>
        {children}
      </div>
    </div>
  )
}

export const Composer = forwardRef<ComposerHandle, Props>(function Composer({ session, running, providers, editing, cancelEdit, onConfig, onSubmitted, aboveInput }, ref) {
  const { run, refreshQueue, refreshPage, queue } = useStore()
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [stopping, setStopping] = useState(false)
  const [pickerOpen, setPickerOpen] = useState(false)
  const ta = useRef<HTMLTextAreaElement>(null)
  const mode = steerMode(session.provider, session.model, providers)
  const pending = queue.filter(q => q.status === 'pending' || q.status === 'dispatching')
  const lastPending = useRef<QueueItem[]>(pending)
  if (pending.length) lastPending.current = pending

  useEffect(() => {
    if (!running) setStopping(false)
  }, [running])

  useImperativeHandle(
    ref,
    () => ({
      focus: () => ta.current?.focus(),
      openPicker: () => setPickerOpen(true),
      setText: t => {
        setText(t)
        requestAnimationFrame(() => {
          const el = ta.current
          if (el) {
            el.focus()
            el.setSelectionRange(t.length, t.length)
          }
        })
      },
    }),
    [],
  )

  useEffect(() => {
    const el = ta.current
    if (!el) return
    el.style.height = '0px'
    el.style.height = `${Math.min(240, Math.max(26, el.scrollHeight))}px`
  }, [text])

  useEffect(() => {
    ta.current?.focus()
  }, [session.thread_id])

  const act = async (kind: 'send' | 'queue' | 'steer') => {
    const prompt = text.trim()
    if (!prompt || busy) return
    setBusy(true)
    const tid = session.thread_id
    const effective = editing ? 'edit' : kind
    const ok = await run(effective === 'steer' ? 'Steer failed' : effective === 'queue' ? 'Could not queue' : effective === 'edit' ? 'Fork failed' : 'Send failed', async () => {
      if (editing) await api.edit(tid, editing.msg_id, prompt, session.provider, session.model)
      else if (kind === 'send') {
        await api.send(tid, prompt, session.provider, session.model)
        if (/^new session$/i.test(session.title) || !session.title.trim()) await api.config(tid, { title: prompt.split('\n')[0].slice(0, 64) })
      } else if (kind === 'queue') await api.enqueue(tid, prompt, session.provider, session.model)
      else await api.steer(tid, prompt, session.provider, session.model)
      return true
    })
    setBusy(false)
    if (!ok) return
    setText('')
    if (editing) cancelEdit()
    refreshQueue()
    onSubmitted(effective)
    if (effective === 'send' || effective === 'edit') setTimeout(refreshPage, 60)
  }

  const stopTurn = async () => {
    if (stopping) return
    setStopping(true)
    await run('Interrupt failed', () => api.interruptThread(session.thread_id))
  }

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape' && editing) {
      cancelEdit()
      setText('')
      return
    }
    if (e.key !== 'Enter' || e.shiftKey || e.nativeEvent.isComposing) return
    e.preventDefault()
    if (editing) act('send')
    else if (running && (e.altKey || e.metaKey || e.ctrlKey)) act('steer')
    else act(running ? 'queue' : 'send')
  }

  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-0 z-10 flex flex-col bg-gradient-to-t from-background from-60% via-background to-transparent px-4 pt-12 pb-4">
      <div className="pointer-events-auto relative mx-auto w-full max-w-3xl">
        {aboveInput ? <div className="absolute bottom-full left-1/2 mb-3 -translate-x-1/2">{aboveInput}</div> : null}
        <div className={cn('overflow-hidden rounded-2xl border bg-background transition-colors duration-200 focus-within:border-foreground/12', running ? 'border-primary/25' : 'border-border')}>
          <Reveal show={!!editing}>
            <div className="flex items-center justify-between border-b border-border bg-sidebar/40 px-4 py-2.5 text-xs text-muted-foreground">
              <div className="flex items-center gap-2">
                <Pencil className="size-3.5" />
                <span>Editing message</span>
                <span className="flex items-center gap-1 text-muted-foreground/70">
                  <GitBranch className="size-3" /> forks a sibling branch · workspace rewinds first
                </span>
              </div>
              <Button
                variant="ghost"
                size="icon-xs"
                onClick={() => {
                  cancelEdit()
                  setText('')
                }}
                aria-label="Cancel edit"
              >
                <X className="size-3.5" />
              </Button>
            </div>
          </Reveal>
          <Reveal show={pending.length > 0 && !editing}>
            <QueueBanner items={pending.length ? pending : lastPending.current} running={running} mode={mode} threadId={session.thread_id} />
          </Reveal>
          <Reveal show={running && !editing}>
            <div className="flex items-center gap-2 px-5 pt-3 text-[11.5px] text-muted-foreground">
              <span className="relative flex size-1.5">
                <span className="absolute inset-0 animate-ping rounded-full bg-primary/60" />
                <span className="relative size-1.5 rounded-full bg-primary" />
              </span>
              Agent is working —
              <span className={cn('font-medium', mode === 'native' ? 'text-primary' : 'text-amber')}>{mode === 'native' ? 'steer injects into the live turn' : 'steer interrupts, then resumes'}</span>
            </div>
          </Reveal>
          <textarea
            ref={ta}
            value={text}
            onChange={e => setText(e.target.value)}
            onKeyDown={onKey}
            rows={1}
            placeholder={editing ? 'Rewrite the message…' : running ? 'Steer the running turn, or queue a follow-up…' : 'Write to the agent…'}
            className="block max-h-60 w-full resize-none bg-transparent px-5 pt-4 pb-1 text-[15px] leading-relaxed outline-none placeholder:text-muted-foreground/70"
          />
          <div className="flex items-center gap-2 px-3 pt-1 pb-3">
            <ModelPicker providers={providers} provider={session.provider} model={session.model} onChange={onConfig} open={pickerOpen} onOpenChange={setPickerOpen} />
            <Tip label={mode === 'native' ? 'This harness accepts steering mid-turn without restarting' : 'This harness is steered by interrupting the turn and resuming with your directive'}>
              <span className={cn('hidden h-7 items-center gap-1 rounded-lg px-2 text-[11.5px] font-medium whitespace-nowrap', !running && 'md:inline-flex', mode === 'native' ? 'text-primary' : 'text-amber')}>
                {mode === 'native' ? <Zap className="size-3" /> : <Repeat className="size-3" />}
                {mode === 'native' ? 'native steer' : 'interrupt & resume'}
              </span>
            </Tip>
            <div className="flex-1" />
            {editing ? (
              <Tip label="Fork a new branch with this message" shortcut="↵">
                <Button className="h-9 rounded-xl px-3.5" onClick={() => act('send')} disabled={!text.trim() || busy}>
                  {busy ? <Loader2 className="animate-spin" /> : <GitBranch />} Fork
                </Button>
              </Tip>
            ) : running ? (
              <>
                <Tip label="Stop the running turn">
                  <Button variant="ghost" className="h-9 rounded-xl px-3 text-destructive hover:bg-danger-soft hover:text-destructive" onClick={stopTurn} disabled={stopping} aria-label="Stop turn">
                    {stopping ? <Loader2 className="size-3.5 animate-spin" /> : <Square className="size-3 fill-current" />} Stop
                  </Button>
                </Tip>
                <Tip label="Queue as the next turn (durable WAL)" shortcut="↵">
                  <Button variant="ghost" className="h-9 rounded-xl px-3 text-muted-foreground" onClick={() => act('queue')} disabled={!text.trim() || busy}>
                    <ListPlus /> Queue
                  </Button>
                </Tip>
                <Tip label={mode === 'native' ? 'Inject into the running turn' : 'Interrupt and resume with this'} shortcut="⌥↵">
                  <Button variant={mode === 'native' ? 'default' : 'amber'} className="h-9 rounded-xl px-3.5" onClick={() => act('steer')} disabled={!text.trim() || busy}>
                    {mode === 'native' ? <Zap /> : <Repeat />} Steer
                  </Button>
                </Tip>
              </>
            ) : (
              <Tip label="Send message" shortcut="↵">
                <Button size="icon" className="size-9 rounded-xl" onClick={() => act('send')} disabled={!text.trim() || busy} aria-label="Send">
                  {busy ? <Loader2 className="animate-spin" /> : <ArrowUp className="size-4" />}
                </Button>
              </Tip>
            )}
          </div>
        </div>
        <div className="mt-2 flex items-center justify-center gap-3 text-[11px] text-muted-foreground/70">
          {editing ? (
            <span className="flex items-center gap-1"><Kbd>↵</Kbd> fork <Kbd>esc</Kbd> cancel</span>
          ) : running ? (
            <>
              <span className="flex items-center gap-1"><Kbd>↵</Kbd> queue</span>
              <span className="flex items-center gap-1"><Kbd>⌥↵</Kbd> steer</span>
            </>
          ) : (
            <span className="flex items-center gap-1"><Kbd>↵</Kbd> send</span>
          )}
          <span className="flex items-center gap-1"><Kbd>⇧↵</Kbd> newline</span>
          <span className="flex items-center gap-1"><Kbd>⌘/</Kbd> model</span>
        </div>
      </div>
    </div>
  )
})

function QueueBanner({ items, running, mode, threadId }: { items: QueueItem[]; running: boolean; mode: 'native' | 'fallback'; threadId: string }) {
  const { run, refreshQueue } = useStore()
  const followUps = items.filter(i => i.kind === 'follow_up' && i.status === 'pending').length
  return (
    <div className="border-b border-border bg-sidebar/40">
      <div className="flex items-center gap-2 px-4 pt-2.5 pb-1 text-xs text-muted-foreground">
        <ListPlus className="size-3.5" />
        <span>Durable queue</span>
        <span className="text-muted-foreground/60">· write-ahead logged</span>
        {!running && followUps ? (
          <Button size="xs" variant="ghost" className="ml-auto" onClick={() => run('Drain failed', () => api.drain(threadId)).then(refreshQueue)}>
            <Play className="size-3" /> Drain {followUps}
          </Button>
        ) : null}
      </div>
      <div className="flex max-h-40 flex-col overflow-y-auto px-2 pb-2">
        {items.map(i => (
          <QueueRow key={i.item_id} item={i} mode={mode} />
        ))}
      </div>
    </div>
  )
}

function QueueRow({ item, mode }: { item: QueueItem; mode: 'native' | 'fallback' }) {
  const { run, refreshQueue } = useStore()
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(item.prompt)
  const steer = item.kind === 'steer'
  const save = async () => {
    const p = draft.trim()
    if (!p) return
    const ok = await run('Could not edit queued item', () => api.queueEdit(item.item_id, p))
    if (ok) {
      setEditing(false)
      refreshQueue()
    }
  }
  return (
    <div className="group/q flex h-9 items-center gap-2 rounded-lg px-2 transition-colors hover:bg-accent/60">
      <span className={cn('inline-flex h-5 shrink-0 items-center gap-1 rounded-md px-1.5 font-mono text-[10.5px]', steer ? (mode === 'native' ? 'bg-primary/10 text-primary' : 'bg-amber-soft text-amber') : 'bg-[var(--wash)] text-muted-foreground')}>
        {steer ? mode === 'native' ? <Zap className="size-3" /> : <Repeat className="size-3" /> : <ListPlus className="size-3" />}
        {steer ? 'steer' : 'next'}
      </span>
      {editing ? (
        <input
          autoFocus
          value={draft}
          onChange={e => setDraft(e.target.value)}
          onKeyDown={e => {
            if (e.key === 'Enter') save()
            if (e.key === 'Escape') setEditing(false)
          }}
          className="h-7 min-w-0 flex-1 rounded-md border border-border bg-background px-2 text-[13px] outline-none focus:border-ring"
        />
      ) : (
        <span className="min-w-0 flex-1 truncate text-[13px]">{item.prompt}</span>
      )}
      {item.status === 'dispatching' ? (
        <span className="flex items-center gap-1 text-[11px] text-primary">
          <Loader2 className="size-3 animate-spin" /> dispatching
        </span>
      ) : editing ? (
        <Button size="icon-xs" variant="ghost" onClick={save} aria-label="Save">
          <Check />
        </Button>
      ) : (
        <span className="flex items-center opacity-0 transition-opacity group-hover/q:opacity-100">
          <Button size="icon-xs" variant="ghost" onClick={() => { setDraft(item.prompt); setEditing(true) }} aria-label="Edit queued message">
            <Pencil />
          </Button>
          <Button size="icon-xs" variant="ghost" onClick={() => run('Could not cancel', () => api.queueCancel(item.item_id)).then(refreshQueue)} aria-label="Cancel queued message">
            <X />
          </Button>
        </span>
      )}
    </div>
  )
}
