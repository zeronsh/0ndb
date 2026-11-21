import { useMemo, useState } from 'react'
import { ChevronRight, FileMinus2, FilePlus2, FileDiff } from 'lucide-react'
import { diffStat, hunks, lineDiff, type DiffLine } from '@/lib/diff'
import { cn } from '@/lib/utils'

export function DiffStat({ added, removed, className }: { added: number; removed: number; className?: string }) {
  if (!added && !removed) return null
  return (
    <span className={cn('inline-flex items-center gap-1.5 font-mono text-[11px] tabular', className)}>
      {added ? <span className="text-ok">+{added}</span> : null}
      {removed ? <span className="text-destructive">−{removed}</span> : null}
    </span>
  )
}

export function DiffLines({ before, after, precomputed, context = 3, className }: { before: string; after: string; precomputed?: DiffLine[]; context?: number; className?: string }) {
  const lines = useMemo(() => precomputed ?? lineDiff(before, after), [precomputed, before, after])
  const hs = useMemo(() => hunks(lines, context), [lines, context])
  if (!hs.length) return <div className="px-3 py-2 text-[12px] text-muted-foreground">No textual changes.</div>
  return (
    <div className={cn('overflow-x-auto font-mono text-[12px] leading-[1.6]', className)}>
      <div className="min-w-max">
        {hs.map((h, hi) => (
          <div key={hi}>
            <div className="bg-violet-soft/60 px-3 py-0.5 text-[11px] text-violet">{h.header}</div>
            {h.lines.map((l, i) => (
              <div
                key={i}
                className={cn(
                  'grid grid-cols-[2.6rem_2.6rem_1.2rem_1fr] pr-4',
                  l.kind === 'add' && 'bg-ok-soft/70 text-foreground',
                  l.kind === 'del' && 'bg-danger-soft/70 text-foreground',
                  l.kind === 'ctx' && 'text-muted-foreground',
                )}
              >
                <span className="select-none pr-2 text-right text-faint/80 tabular">{l.a ?? ''}</span>
                <span className="select-none pr-2 text-right text-faint/80 tabular">{l.b ?? ''}</span>
                <span className={cn('select-none text-center', l.kind === 'add' ? 'text-ok' : l.kind === 'del' ? 'text-destructive' : 'text-transparent')}>{l.kind === 'add' ? '+' : l.kind === 'del' ? '−' : ' '}</span>
                <span className="whitespace-pre">{l.text || ' '}</span>
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  )
}

export function FileDiffCard({ path, status, before, after, defaultOpen = true }: { path: string; status: 'added' | 'removed' | 'modified'; before: string | null; after: string | null; defaultOpen?: boolean }) {
  const [open, setOpen] = useState(defaultOpen)
  const diffLines = useMemo(() => lineDiff(before ?? '', after ?? ''), [before, after])
  const stat = useMemo(() => diffStat(diffLines), [diffLines])
  const Icon = status === 'added' ? FilePlus2 : status === 'removed' ? FileMinus2 : FileDiff
  return (
    <div className="overflow-hidden rounded-xl border border-border bg-card">
      <button onClick={() => setOpen(o => !o)} className="flex h-9 w-full items-center gap-2 px-3 text-left transition-colors hover:bg-accent/60">
        <ChevronRight className={cn('size-3.5 text-faint transition-transform', open && 'rotate-90')} />
        <Icon className={cn('size-3.5', status === 'added' ? 'text-ok' : status === 'removed' ? 'text-destructive' : 'text-muted-foreground')} />
        <span className="truncate font-mono text-[12px]">{path}</span>
        {status !== 'modified' ? <span className="rounded bg-muted px-1 text-[10px] font-medium text-muted-foreground">{status}</span> : null}
        <DiffStat added={stat.added} removed={stat.removed} className="ml-auto" />
      </button>
      {open ? <DiffLines before={before ?? ''} after={after ?? ''} precomputed={diffLines} className="border-t border-hairline py-1" /> : null}
    </div>
  )
}
