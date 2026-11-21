import { useCallback, useEffect, useMemo, useRef, useState, type RefObject } from 'react'
import { Eye, FileDiff, GitMerge, Loader2, PenLine, Save, Undo2, Users, ChevronRight } from 'lucide-react'
import { toast } from 'sonner'
import { api, type BlameLine, type FilesChangedEvent } from '@/lib/api'
import { diffStat, lineDiff } from '@/lib/diff'
import { ago, bytes, shortId } from '@/lib/format'
import { langFromPath } from '@/lib/highlight'
import { applyUtf8Splices, changedLinesFromSplices, computeUtf8Splices, utf16ToUtf8Offset, utf8ToUtf16Offset } from '@/lib/splices'
import { useStore, type FileActivity } from '@/lib/store'
import { cn } from '@/lib/utils'
import { DiffLines } from '../diff-view'
import { Button } from '../ui/button'
import { Kbd } from '../ui/kbd'
import { Tip } from '../ui/tooltip'
import { CopyButton } from '../copy-button'
import { CodeView } from './code-view'
import { FileIcon } from './file-icon'

type Mode = 'view' | 'edit' | 'blame' | 'diff'

const ACTOR: Record<string, string> = {
  seed: 'bg-violet-soft text-violet',
  agent: 'bg-primary/10 text-primary',
  disk: 'bg-amber-soft text-amber',
  watch: 'bg-amber-soft text-amber',
  editor: 'bg-ok-soft text-ok',
}

function stripTrailingNewline(s: string) {
  return s.endsWith('\n') ? s.slice(0, -1) : s
}

function countDisplayLines(s: string) {
  if (!s.length) return 0
  return stripTrailingNewline(s).split('\n').length
}

export function FileViewer({ path, activity }: { path: string; activity: FileActivity | undefined }) {
  const { onFilesChanged, run, refreshInfo } = useStore()
  const [content, setContent] = useState<string | null>(null)
  const [previous, setPrevious] = useState<string | null>(null)
  const [changed, setChanged] = useState<number[]>([])
  const [flashKey, setFlashKey] = useState(0)
  const [mode, setMode] = useState<Mode>('view')
  const [draft, setDraft] = useState('')
  const [mergeBadge, setMergeBadge] = useState<{ added: number; removed: number; at: number } | null>(null)
  const [blame, setBlame] = useState<BlameLine[] | null>(null)
  const [saving, setSaving] = useState(false)

  const serverContentRef = useRef<string | null>(null)
  const serverVersionRef = useRef<string | null>(null)
  const draftBaseVersionRef = useRef<string | null>(null)
  const draftRef = useRef('')
  const draftSeqRef = useRef(0)
  const modeRef = useRef<Mode>('view')
  const savingRef = useRef(false)
  const rebasingRef = useRef(false)
  const pendingRebaseRef = useRef(false)
  const activityRef = useRef(activity)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const editorScrollerRef = useRef<HTMLDivElement>(null)

  activityRef.current = activity
  modeRef.current = mode
  savingRef.current = saving

  const dirty = mode === 'edit' && content != null && draft !== content
  const dirtyRef = useRef(dirty)
  dirtyRef.current = dirty

  const updateDraft = useCallback((next: string) => {
    draftSeqRef.current += 1
    draftRef.current = next
    setDraft(next)
  }, [])

  const load = useCallback(async () => {
    const r = await api.file(path).catch(() => null)
    if (!r) return
    const next = r.content ?? ''
    const ver = r.version ?? null
    const prev = serverContentRef.current
    serverContentRef.current = next
    serverVersionRef.current = ver
    setContent(next)
    if (!dirtyRef.current) {
      draftBaseVersionRef.current = ver
      draftRef.current = next
      setDraft(next)
    }
    const act = activityRef.current
    if (prev != null && prev !== next) {
      setPrevious(prev)
      const d = lineDiff(stripTrailingNewline(prev), stripTrailingNewline(next))
      const idx: number[] = []
      for (const l of d) if (l.kind === 'add' && l.b != null) idx.push(l.b - 1)
      setChanged(idx)
      setFlashKey(k => k + 1)
    } else if (prev == null && act && Date.now() - act.ts < 12000 && act.splices?.length && (!act.to_version || act.to_version === ver)) {
      const idx = changedLinesFromSplices(next, act.splices)
      if (idx.length) {
        setChanged(idx)
        setFlashKey(k => k + 1)
      }
    }
  }, [path])

  const rebaseWorkingBuffer = useCallback(async () => {
    if (rebasingRef.current) {
      pendingRebaseRef.current = true
      return
    }
    const baseVer = draftBaseVersionRef.current
    if (!baseVer || !dirtyRef.current) return
    rebasingRef.current = true
    try {
      while (true) {
        pendingRebaseRef.current = false
        const curBase = draftBaseVersionRef.current
        if (!curBase || !dirtyRef.current) break
        const snapDraft = draftRef.current
        const snapSeq = draftSeqRef.current
        const el = textareaRef.current
        const scroller = editorScrollerRef.current
        const selStart16 = el ? el.selectionStart : 0
        const selEnd16 = el ? el.selectionEnd : 0
        const scrollTop = scroller ? scroller.scrollTop : 0
        const utf8Start = utf16ToUtf8Offset(snapDraft, selStart16)
        const utf8End = utf16ToUtf8Offset(snapDraft, selEnd16)

        const rb = await api.rebaseFile(path, curBase, snapDraft, utf8Start, utf8End).catch(() => null)
        if (!rb || !rb.ok || rb.reload || !rb.version) {
          await load()
          break
        }
        if (draftSeqRef.current !== snapSeq) {
          pendingRebaseRef.current = true
          continue
        }
        const splices = rb.splices ?? []
        const mergedDraft = splices.length ? applyUtf8Splices(snapDraft, splices) : snapDraft
        draftBaseVersionRef.current = rb.version
        draftRef.current = mergedDraft
        setDraft(mergedDraft)

        const nextStart16 = utf8ToUtf16Offset(mergedDraft, rb.cursor_start ?? utf8Start)
        const nextEnd16 = utf8ToUtf16Offset(mergedDraft, rb.cursor_end ?? utf8End)
        requestAnimationFrame(() => {
          const box = textareaRef.current
          if (box && document.activeElement === box) {
            box.setSelectionRange(nextStart16, nextEnd16)
          }
          if (editorScrollerRef.current) {
            editorScrollerRef.current.scrollTop = scrollTop
          }
        })

        if (splices.length) {
          setMergeBadge({ added: rb.added ?? 0, removed: rb.removed ?? 0, at: Date.now() })
        }
        if (!pendingRebaseRef.current) break
      }
    } finally {
      rebasingRef.current = false
    }
  }, [path, load])

  useEffect(() => {
    serverContentRef.current = null
    serverVersionRef.current = null
    draftBaseVersionRef.current = null
    draftRef.current = ''
    draftSeqRef.current = 0
    setContent(null)
    setPrevious(null)
    setChanged([])
    setFlashKey(0)
    setBlame(null)
    setMergeBadge(null)
    setMode(m => (m === 'diff' ? 'view' : m))
    load()
  }, [path, load])

  useEffect(() => {
    return onFilesChanged((ev: FilesChangedEvent) => {
      const ch = ev.changes.find(c => c.path === path)
      if (!ch) return
      if (ev.to_version && serverVersionRef.current === ev.to_version) return
      if (savingRef.current && ev.source === 'editor') return

      if (ch.kind === 'removed') {
        serverVersionRef.current = ev.to_version ?? serverVersionRef.current
        if (!dirtyRef.current) {
          serverContentRef.current = ''
          draftBaseVersionRef.current = ev.to_version ?? draftBaseVersionRef.current
          draftRef.current = ''
          setContent('')
          setDraft('')
        }
        return
      }

      const curServer = serverContentRef.current
      const canPatch = curServer != null && ev.from_version != null && serverVersionRef.current === ev.from_version && Array.isArray(ch.splices)

      if (canPatch) {
        const nextServer = applyUtf8Splices(curServer, ch.splices!)
        serverContentRef.current = nextServer
        serverVersionRef.current = ev.to_version ?? serverVersionRef.current
        if (nextServer !== curServer) {
          setPrevious(curServer)
          setChanged(changedLinesFromSplices(nextServer, ch.splices!))
          setFlashKey(k => k + 1)
        }
        setContent(nextServer)
        if (dirtyRef.current) {
          rebaseWorkingBuffer()
        } else {
          draftBaseVersionRef.current = ev.to_version ?? draftBaseVersionRef.current
          draftRef.current = nextServer
          setDraft(nextServer)
        }
      } else if (dirtyRef.current) {
        api
          .file(path)
          .then(r => {
            if (!r) return
            const nextServer = r.content ?? ''
            if (serverContentRef.current != null && serverContentRef.current !== nextServer) setPrevious(serverContentRef.current)
            serverContentRef.current = nextServer
            serverVersionRef.current = r.version ?? serverVersionRef.current
            setContent(nextServer)
            rebaseWorkingBuffer()
          })
          .catch(() => undefined)
      } else {
        load()
      }
    })
  }, [path, onFilesChanged, load, rebaseWorkingBuffer])

  useEffect(() => {
    if (!mergeBadge) return
    const t = setTimeout(() => setMergeBadge(null), 5000)
    return () => clearTimeout(t)
  }, [mergeBadge])

  useEffect(() => {
    if (mode !== 'blame') return
    let alive = true
    api
      .blame(path)
      .then(r => alive && setBlame(r.lines))
      .catch(() => alive && setBlame([]))
    return () => {
      alive = false
    }
  }, [mode, path, content])

  const save = async () => {
    if (!dirty || saving) return
    setSaving(true)
    const baseVer = draftBaseVersionRef.current
    const baseContent = serverContentRef.current
    const nextDraft = draftRef.current
    const res = await run('Save failed', () => {
      if (baseVer && baseContent != null && serverVersionRef.current === baseVer) {
        const patch = computeUtf8Splices(baseContent, nextDraft)
        if (patch.splices.length > 0) {
          return api.saveFileSplices(path, baseVer, patch.splices, patch.inserted)
        }
      }
      return api.writeFile(path, nextDraft, baseVer ?? undefined)
    })
    setSaving(false)
    if (res?.ok) {
      serverContentRef.current = res.content
      serverVersionRef.current = res.version
      draftBaseVersionRef.current = res.version
      draftRef.current = res.content
      setContent(res.content)
      setDraft(res.content)
      toast.success(res.merged ? `Merged & committed ${path}` : `Committed ${path}`, {
        description: res.merged ? 'Concurrent edits were surgically merged by the CRDT.' : 'Diffed into CRDT splices — a new causal batch.',
      })
      refreshInfo()
    }
  }

  const lang = langFromPath(path)
  const displayCode = content != null ? stripTrailingNewline(content) : null
  const displayPrev = previous != null ? stripTrailingNewline(previous) : null
  const stat = useMemo(() => (displayPrev != null && displayCode != null ? diffStat(lineDiff(displayPrev, displayCode)) : null), [displayPrev, displayCode])
  const parts = path.split('/')
  const lineCount = content != null ? countDisplayLines(content) : 0
  const recent = activity && Date.now() - activity.ts < 12000

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex h-11 shrink-0 items-center gap-2 border-b border-border pr-2 pl-3">
        <FileIcon path={path} />
        <div className="flex min-w-0 flex-1 items-center gap-1 text-[12.5px]">
          {parts.length > 1 ? (
            <>
              <span className="min-w-0 truncate text-muted-foreground [direction:rtl]">{parts.slice(0, -1).join(' / ')}</span>
              <ChevronRight className="size-3 shrink-0 text-muted-foreground/50" />
            </>
          ) : null}
          <span className="shrink-0 font-medium text-foreground">{parts.at(-1)}</span>
        </div>
        {mergeBadge && mode === 'edit' ? (
          <span key={mergeBadge.at} className="flex shrink-0 items-center gap-1 rounded-full bg-ok-soft px-2 py-0.5 font-mono text-[10.5px] font-medium text-ok animate-rise">
            <GitMerge className="size-3" /> merged
            {mergeBadge.added ? <span>+{mergeBadge.added}</span> : null}
            {mergeBadge.removed ? <span className="text-destructive">−{mergeBadge.removed}</span> : null}
          </span>
        ) : recent ? (
          <span key={activity!.ts} className="flex shrink-0 items-center gap-1.5 rounded-full bg-ok-soft px-2 py-0.5 text-[10.5px] font-medium text-ok animate-rise">
            <span className="size-1.5 rounded-full bg-ok [animation:dot-breathe_1.2s_ease-in-out_infinite]" /> live
          </span>
        ) : null}
        {dirty ? <span className="size-1.5 shrink-0 rounded-full bg-amber" title="Unsaved changes" /> : null}
        <span className="ml-auto inline-flex h-7 shrink-0 rounded-lg bg-[var(--wash)] p-0.5">
          {(
            [
              ['view', Eye, 'View'],
              ['edit', PenLine, 'Edit'],
              ['blame', Users, 'Blame'],
              ['diff', FileDiff, 'Diff'],
            ] as const
          ).map(([m, Icon, label]) => (
            <Tip key={m} label={m === 'diff' ? (displayPrev != null ? 'What the last live change did' : 'No live change yet') : label}>
              <button
                disabled={m === 'diff' && displayPrev == null}
                onClick={() => {
                  if (m === 'edit' && mode !== 'edit') {
                    const base = serverContentRef.current ?? ''
                    draftBaseVersionRef.current = serverVersionRef.current
                    draftRef.current = base
                    setDraft(base)
                  }
                  setMode(m)
                }}
                className={cn('flex items-center gap-1 rounded-md px-2 text-[11.5px] font-medium transition disabled:opacity-35', mode === m ? 'bg-background text-foreground shadow-sm' : 'text-muted-foreground hover:text-foreground')}
              >
                <Icon className="size-3" />
                <span className="hidden @[520px]:inline">{label}</span>
              </button>
            </Tip>
          ))}
        </span>
        {content != null ? <CopyButton text={content} label="Copy file" /> : null}
      </div>
      <div className="relative min-h-0 flex-1">
        {content == null ? (
          <div className="flex items-center gap-2 px-4 py-4 text-[12px] text-muted-foreground">
            <Loader2 className="size-3.5 animate-spin" /> Reading from the CRDT tree…
          </div>
        ) : mode === 'view' ? (
          <CodeView code={displayCode ?? ''} lang={lang} changed={changed} flashKey={flashKey} />
        ) : mode === 'edit' ? (
          <Editor draft={draft} setDraft={updateDraft} onSave={save} textareaRef={textareaRef} scrollerRef={editorScrollerRef} />
        ) : mode === 'diff' && displayPrev != null ? (
          <div className="absolute inset-0 overflow-auto py-2">
            <DiffLines before={displayPrev} after={displayCode ?? ''} className="text-[12px] leading-[20px]" />
          </div>
        ) : (
          <BlameView lines={blame} />
        )}
      </div>
      <div className="flex h-9 shrink-0 items-center gap-2 overflow-hidden border-t border-border px-3 text-[11px] whitespace-nowrap text-muted-foreground">
        <span className="font-mono tabular">{lineCount} lines</span>
        <span className="opacity-50">·</span>
        <span>{lang ?? 'text'}</span>
        {content != null ? (
          <>
            <span className="opacity-50">·</span>
            <span className="font-mono tabular">{bytes(new TextEncoder().encode(content).length)}</span>
          </>
        ) : null}
        {mode === 'edit' ? (
          <span className="ml-auto flex items-center gap-1.5">
            <Button
              size="xs"
              variant="ghost"
              onClick={() => {
                const base = serverContentRef.current ?? ''
                draftBaseVersionRef.current = serverVersionRef.current
                updateDraft(base)
              }}
              disabled={!dirty}
            >
              <Undo2 className="size-3" /> Revert
            </Button>
            <Button size="xs" onClick={save} disabled={!dirty || saving}>
              {saving ? <Loader2 className="size-3 animate-spin" /> : <Save className="size-3" />} Commit
              <Kbd className="h-4 border-white/20 bg-white/10 text-[9.5px] text-primary-foreground shadow-none dark:border-black/10 dark:bg-black/5">⌘S</Kbd>
            </Button>
          </span>
        ) : activity ? (
          <span className="ml-auto flex min-w-0 items-center gap-1.5">
            {stat ? (
              <span className="font-mono tabular">
                <span className="text-ok">+{stat.added}</span> <span className="text-destructive">−{stat.removed}</span>
              </span>
            ) : null}
            <span className="truncate">
              {activity.kind} by {activity.source}
              {activity.msg_id ? <span className="font-mono"> · {shortId(activity.msg_id)}</span> : null} · {ago(activity.ts)}
            </span>
          </span>
        ) : null}
      </div>
    </div>
  )
}

function Editor({
  draft,
  setDraft,
  onSave,
  textareaRef,
  scrollerRef,
}: {
  draft: string
  setDraft: (s: string) => void
  onSave: () => void
  textareaRef: RefObject<HTMLTextAreaElement | null>
  scrollerRef: RefObject<HTMLDivElement | null>
}) {
  const n = draft.split('\n').length
  return (
    <div ref={scrollerRef} className="absolute inset-0 overflow-auto">
      <div className="flex min-h-full py-3 font-mono text-[12.5px] leading-[20px]">
        <div className="sticky left-0 z-[1] shrink-0 bg-background pr-4 pl-4 text-right text-muted-foreground/50 select-none tabular">
          {Array.from({ length: n }, (_, i) => (
            <div key={i}>{i + 1}</div>
          ))}
        </div>
        <textarea
          ref={textareaRef}
          value={draft}
          spellCheck={false}
          autoFocus
          onChange={e => setDraft(e.target.value)}
          onKeyDown={e => {
            if ((e.metaKey || e.ctrlKey) && e.key === 's') {
              e.preventDefault()
              onSave()
            }
            if (e.key === 'Tab') {
              e.preventDefault()
              const el = e.currentTarget
              const { selectionStart: a, selectionEnd: b } = el
              setDraft(draft.slice(0, a) + '    ' + draft.slice(b))
              requestAnimationFrame(() => el.setSelectionRange(a + 4, a + 4))
            }
          }}
          className="w-full flex-1 resize-none bg-transparent pr-4 whitespace-pre outline-none"
          style={{ height: n * 20 + 4 }}
        />
      </div>
    </div>
  )
}

function BlameView({ lines }: { lines: BlameLine[] | null }) {
  if (!lines)
    return (
      <div className="flex items-center gap-2 px-4 py-4 text-[12px] text-muted-foreground">
        <Loader2 className="size-3.5 animate-spin" /> Walking CRDT insertions…
      </div>
    )
  if (!lines.length) return <div className="px-4 py-4 text-[12px] text-muted-foreground">Empty file — nothing to blame.</div>
  return (
    <div className="absolute inset-0 overflow-auto">
      <div className="min-w-max py-2 font-mono text-[12.5px] leading-[20px]">
        {lines.map((l, i) => {
          const prev = lines[i - 1]
          const first = !prev || prev.actor !== l.actor || prev.ts !== l.ts
          const label = l.actor_label ?? 'actor'
          return (
            <div key={l.line_no} className={cn('grid grid-cols-[8.5rem_2.6rem_1fr] hover:bg-accent/50', first && i > 0 && 'border-t border-border')}>
              <Tip side="left" label={<span className="font-mono">actor {shortId(l.actor, 12)} · lamport {l.ts}</span>}>
                <span className="flex items-center gap-1.5 truncate pr-2 pl-3 font-sans text-[11px]">
                  {first ? (
                    <>
                      <span className={cn('inline-flex h-[17px] items-center rounded px-1 text-[10px] font-medium', ACTOR[label] ?? 'bg-muted text-muted-foreground')}>{label}</span>
                      <span className="truncate text-muted-foreground/70">{l.wall_ms ? ago(l.wall_ms) : `ts ${l.ts}`}</span>
                    </>
                  ) : null}
                </span>
              </Tip>
              <span className="pr-3 text-right text-muted-foreground/50 select-none tabular">{l.line_no}</span>
              <span className="pr-4 whitespace-pre">{l.text || ' '}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}
