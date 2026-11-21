import { useMemo, useState } from 'react'
import { AlertTriangle, ChevronRight, CircleSlash, ClipboardList, Download, FilePenLine, FilePlus2, FileText, FolderOpen, Globe, ListChecks, Loader2, Search, SquareTerminal, Users, Wrench } from 'lucide-react'
import { parseAnsi } from '@/lib/ansi'
import { hunks, lineDiff } from '@/lib/diff'
import { langFromPath } from '@/lib/highlight'
import type { ToolKind, ToolView } from '@/lib/tools'
import { cn } from '@/lib/utils'
import { AnsiText } from '../ansi-text'
import { Highlighted } from '../code-block'
import { CopyButton } from '../copy-button'
import { DiffLines, DiffStat } from '../diff-view'

export const KIND_ICON: Record<ToolKind, typeof Wrench> = {
  run: SquareTerminal,
  read: FileText,
  write: FilePlus2,
  edit: FilePenLine,
  search: Search,
  list: FolderOpen,
  web: Globe,
  fetch: Download,
  plan: ListChecks,
  agent: Users,
  tool: Wrench,
}

export const TOOL_ROW_H = 32
const HEAD_H = 36
const LINE_H = 19
const PAD = 20
const CAP = 16
const FOOT_H = 26

function bodyLines(view: ToolView) {
  if (view.edit) {
    const hs = hunks(lineDiff(view.edit.before, view.edit.after))
    return Math.max(1, hs.reduce((a, h) => a + h.lines.length + 1, 0))
  }
  if (view.kind === 'write' && view.content) return view.content.replace(/\n$/, '').split('\n').length
  if (!view.output) return 1
  return parseAnsi(view.output).length
}

export function toolDetailHeight(view: ToolView) {
  const n = Math.min(CAP, bodyLines(view))
  const foot = view.kind === 'write' && view.content && view.output ? FOOT_H : 0
  return HEAD_H + PAD + n * LINE_H + foot + 2
}

export function ToolRowView({ view, open, onToggle }: { view: ToolView; open: boolean; onToggle: () => void }) {
  const Icon = view.status === 'running' ? Loader2 : view.status === 'failed' ? AlertTriangle : view.status === 'interrupted' ? CircleSlash : KIND_ICON[view.kind]
  return (
    <button
      onClick={onToggle}
      aria-expanded={open}
      className={cn('group/row flex h-full w-full min-w-0 items-center gap-2 rounded-lg border border-transparent px-2.5 text-left text-[12.5px] transition-colors duration-150', open ? 'border-border bg-[var(--wash)]' : 'hover:bg-[var(--wash)]')}
    >
      <Icon className={cn('size-3.5 shrink-0', view.status === 'running' && 'animate-spin text-primary', view.status === 'failed' && 'text-destructive', view.status === 'done' && 'text-muted-foreground', view.status === 'interrupted' && 'text-amber')} />
      <span className="shrink-0 font-medium text-foreground/80">{view.verb}</span>
      {view.target ? <span className={cn('min-w-0 truncate text-muted-foreground', view.code && 'font-mono text-[11.5px]')}>{view.target}</span> : null}
      {view.detail ? <span className="hidden min-w-0 truncate text-muted-foreground/60 sm:inline">{view.detail}</span> : null}
      <span className="ml-auto flex shrink-0 items-center gap-2 pl-2">
        {view.kind === 'edit' || view.kind === 'write' ? <DiffStat added={view.added} removed={view.removed} /> : null}
        {view.status === 'interrupted' ? <span className="text-[11px] text-amber">interrupted</span> : null}
        {view.time ? <span className="font-mono text-[10px] text-muted-foreground/70 tabular">{view.time}</span> : null}
        <ChevronRight className={cn('size-3 text-muted-foreground/60 transition-transform duration-200', open && 'rotate-90')} />
      </span>
    </button>
  )
}

export function ToolDetailBox({ view, height }: { view: ToolView; height: number }) {
  const [tab, setTab] = useState<'result' | 'input'>('result')
  const pretty = useMemo(() => {
    try {
      return JSON.stringify(JSON.parse(view.rawInput), null, 2)
    } catch {
      return view.rawInput
    }
  }, [view.rawInput])
  const foot = view.kind === 'write' && view.content && view.output
  const bodyH = height - HEAD_H - 2 - (foot ? FOOT_H : 0)
  return (
    <div className="pl-6" style={{ height }}>
      <div className="flex h-full flex-col overflow-hidden rounded-xl border border-border bg-[var(--wash)]">
        <div className="flex shrink-0 items-center gap-2 border-b border-border pr-1.5 pl-3" style={{ height: HEAD_H }}>
          {view.command != null ? (
            <span className="flex min-w-0 items-center gap-2 font-mono text-[12px]">
              <span className="select-none text-primary">$</span>
              <span className="truncate">{view.command.split('\n')[0]}</span>
            </span>
          ) : (
            <span className="min-w-0 truncate font-mono text-[12px]">{view.path ?? view.verb}</span>
          )}
          <span className="ml-auto flex shrink-0 items-center gap-0.5">
            <span className="mr-1 inline-flex h-6 rounded-md bg-[var(--wash)] p-0.5 text-[11px]">
              {(['result', 'input'] as const).map(t => (
                <button key={t} onClick={() => setTab(t)} className={cn('rounded-[5px] px-1.5 capitalize transition', tab === t ? 'bg-background text-foreground shadow-sm' : 'text-muted-foreground hover:text-foreground')}>
                  {t}
                </button>
              ))}
            </span>
            {view.command ? <CopyButton text={view.command} label="Copy command" /> : view.path ? <CopyButton text={view.path} label="Copy path" /> : null}
            {view.output ? <CopyButton text={view.outputPlain} label="Copy output" icon={<ClipboardList className="size-3.5" />} /> : null}
          </span>
        </div>
        <div className="min-h-0 overflow-auto" style={{ height: bodyH }}>
          {tab === 'input' ? (
            <Highlighted code={pretty || '{}'} lang="json" className="px-3.5 py-2.5 text-[12px] leading-[19px]" />
          ) : view.edit ? (
            <DiffLines before={view.edit.before} after={view.edit.after} className="py-1 text-[12px] leading-[19px]" />
          ) : view.kind === 'write' && view.content ? (
            <Highlighted code={view.content.replace(/\n$/, '')} lang={view.path ? langFromPath(view.path) : null} className="px-3.5 py-2.5 text-[12px] leading-[19px] [&_pre]:min-w-max" />
          ) : view.output ? (
            <AnsiText text={view.output} className={cn('px-3.5 py-2.5 text-[12px] leading-[19px]', view.status === 'failed' && 'text-destructive')} />
          ) : (
            <div className="px-3.5 py-2.5 font-mono text-[12px] leading-[19px] text-muted-foreground">{view.status === 'running' ? <span className="text-shimmer">waiting for output…</span> : 'no output'}</div>
          )}
        </div>
        {foot ? (
          <div className="flex shrink-0 items-center border-t border-border px-3.5 font-mono text-[11px] text-muted-foreground" style={{ height: FOOT_H }}>
            {view.outputPlain}
          </div>
        ) : null}
      </div>
    </div>
  )
}
