import { useEffect, useMemo, useState } from 'react'
import { ChevronRight, FilePlus2, HardDriveDownload, Search, X } from 'lucide-react'
import type { FileEntry } from '@/lib/api'
import type { FileActivity } from '@/lib/store'
import { cn } from '@/lib/utils'
import { Button } from '../ui/button'
import { Tip } from '../ui/tooltip'
import { FileIcon, FolderIcon } from './file-icon'

interface Node {
  name: string
  path: string
  dir: boolean
  children: Node[]
  file?: FileEntry
}

function build(files: FileEntry[]): Node {
  const root: Node = { name: '', path: '', dir: true, children: [] }
  for (const f of files) {
    const parts = f.path.split('/')
    let cur = root
    parts.forEach((part, i) => {
      const p = parts.slice(0, i + 1).join('/')
      const leaf = i === parts.length - 1
      let next = cur.children.find(c => c.name === part && c.dir === !leaf)
      if (!next) {
        next = { name: part, path: p, dir: !leaf, children: [], file: leaf ? f : undefined }
        cur.children.push(next)
      } else if (leaf) next.file = f
      cur = next
    })
  }
  const sort = (n: Node) => {
    n.children.sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1))
    n.children.forEach(sort)
  }
  sort(root)
  return root
}

const RECENT_MS = 12000

function useTicker(ms: number) {
  const [, set] = useState(0)
  useEffect(() => {
    const t = setInterval(() => set(x => x + 1), ms)
    return () => clearInterval(t)
  }, [ms])
}

export function FileTree({
  files,
  selected,
  onSelect,
  activity,
  onCreate,
  onIngest,
}: {
  files: FileEntry[]
  selected: string | null
  onSelect: (p: string) => void
  activity: Record<string, FileActivity>
  onCreate: (p: string) => void
  onIngest: () => void
}) {
  useTicker(2000)
  const [filter, setFilter] = useState('')
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase()
    return q ? files.filter(f => f.path.toLowerCase().includes(q)) : files
  }, [files, filter])
  const tree = useMemo(() => build(shown), [shown])
  const now = Date.now()

  const recentUnder = (n: Node): FileActivity | null => {
    if (!n.dir) {
      const a = activity[n.path]
      return a && now - a.ts < RECENT_MS ? a : null
    }
    let best: FileActivity | null = null
    for (const c of n.children) {
      const a = recentUnder(c)
      if (a && (!best || a.ts > best.ts)) best = a
    }
    return best
  }

  const toggle = (p: string) =>
    setCollapsed(prev => {
      const next = new Set(prev)
      if (next.has(p)) next.delete(p)
      else next.add(p)
      return next
    })

  const render = (n: Node, depth: number) =>
    n.children.map(c => {
      const recent = recentUnder(c)
      if (c.dir) {
        const open = !!filter || !collapsed.has(c.path)
        return (
          <div key={`d:${c.path}`}>
            <button
              onClick={() => toggle(c.path)}
              className="group flex h-7 w-full items-center gap-1.5 rounded-md pr-2 text-left text-[12.5px] text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              style={{ paddingLeft: 6 + depth * 12 }}
            >
              <ChevronRight className={cn('size-3 shrink-0 opacity-60 transition-transform duration-200', open && 'rotate-90')} />
              <FolderIcon open={open} />
              <span className="min-w-0 flex-1 truncate">{c.name}</span>
              {recent ? <span key={recent.ts} className="size-1.5 shrink-0 rounded-full bg-primary [animation:dot-breathe_1.4s_ease-in-out_3]" /> : null}
            </button>
            <div className={cn('grid transition-[grid-template-rows] duration-200 ease-out', open ? 'grid-rows-[1fr]' : 'grid-rows-[0fr]')}>
              <div className="min-h-0 overflow-hidden">{render(c, depth + 1)}</div>
            </div>
          </div>
        )
      }
      const act = activity[c.path]
      const isRecent = !!recent
      const badge = act ? (act.kind === 'added' ? 'A' : act.kind === 'removed' ? 'D' : 'M') : null
      return (
        <button
          key={`f:${c.path}:${isRecent ? act?.ts : 0}`}
          onClick={() => onSelect(c.path)}
          className={cn(
            'group relative flex h-7 w-full items-center gap-1.5 rounded-md pr-2 text-left text-[12.5px] transition-colors',
            c.path === selected ? 'bg-accent text-foreground' : 'text-foreground/80 hover:bg-accent/70 hover:text-foreground',
            isRecent && 'node-pulse',
          )}
          style={{ paddingLeft: 6 + depth * 12 + 15 }}
        >
          <FileIcon path={c.path} />
          <span className={cn('min-w-0 flex-1 truncate', act?.kind === 'added' && 'text-ok', act?.kind === 'removed' && 'text-destructive line-through')}>{c.name}</span>
          {isRecent && act ? (
            <span className="flex shrink-0 items-center gap-1 font-mono text-[10px] tabular">
              {act.added ? <span className="text-ok">+{act.added}</span> : null}
              {act.removed ? <span className="text-destructive">−{act.removed}</span> : null}
            </span>
          ) : c.file?.lines != null ? (
            <span className="shrink-0 font-mono text-[10px] text-muted-foreground/60 opacity-0 transition-opacity group-hover:opacity-100 tabular">{c.file.lines}L</span>
          ) : null}
          {badge ? (
            <Tip label={`${act!.kind} by ${act!.source}`}>
              <span className={cn('w-3 shrink-0 text-center font-mono text-[10px] font-medium', badge === 'A' ? 'text-ok' : badge === 'D' ? 'text-destructive' : 'text-amber')}>{badge}</span>
            </Tip>
          ) : (
            <span className="w-3 shrink-0" />
          )}
        </button>
      )
    })

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-1 px-2 pt-2 pb-1.5">
        <div className="flex h-7 min-w-0 flex-1 items-center gap-1.5 rounded-lg bg-[var(--wash)] px-2">
          <Search className="size-3 shrink-0 text-muted-foreground" />
          <input value={filter} onChange={e => setFilter(e.target.value)} placeholder="Filter files" className="h-full min-w-0 flex-1 bg-transparent text-[12px] outline-none placeholder:text-muted-foreground/70" />
          {filter ? (
            <button onClick={() => setFilter('')} className="text-muted-foreground hover:text-foreground" aria-label="Clear filter">
              <X className="size-3" />
            </button>
          ) : null}
        </div>
        <Tip label="New file">
          <Button size="icon-xs" variant="ghost" onClick={() => setCreating(c => !c)}>
            <FilePlus2 />
          </Button>
        </Tip>
        <Tip label="Ingest external disk edits into the CRDT">
          <Button size="icon-xs" variant="ghost" onClick={onIngest}>
            <HardDriveDownload />
          </Button>
        </Tip>
      </div>
      <div className={cn('grid transition-[grid-template-rows] duration-200', creating ? 'grid-rows-[1fr]' : 'grid-rows-[0fr]')}>
        <div className="min-h-0 overflow-hidden">
          <div className="px-2 pb-1.5">
            <input
              value={name}
              onChange={e => setName(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter' && name.trim()) {
                  onCreate(name.trim())
                  setName('')
                  setCreating(false)
                }
                if (e.key === 'Escape') setCreating(false)
              }}
              placeholder="src/new_module.zig  ↵"
              className="h-7 w-full rounded-lg border border-border bg-background px-2 font-mono text-[11.5px] outline-none focus:border-ring"
            />
          </div>
        </div>
      </div>
      <div className="fade-y-edges min-h-0 flex-1 overflow-y-auto px-1.5 py-1">
        {render(tree, 0)}
        {!shown.length ? <div className="px-3 py-6 text-center text-[12px] text-muted-foreground">{filter ? 'No files match.' : 'No tracked files yet.'}</div> : null}
      </div>
    </div>
  )
}
