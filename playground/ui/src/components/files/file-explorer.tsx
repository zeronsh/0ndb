import { useCallback, useEffect, useState } from 'react'
import { Crosshair, FolderTree } from 'lucide-react'
import { toast } from 'sonner'
import { api, type FileEntry, type FilesChangedEvent } from '@/lib/api'
import { ago } from '@/lib/format'
import { useStore } from '@/lib/store'
import { usePersistent } from '@/lib/theme'
import { cn } from '@/lib/utils'
import { Tip } from '../ui/tooltip'
import { FileTree } from './file-tree'
import { FileViewer } from './file-viewer'
import { FileIcon } from './file-icon'

export function FileExplorer() {
  const { conn, onFilesChanged, fileActivity, fileFeed, run, refreshInfo } = useStore()
  const [files, setFiles] = useState<FileEntry[]>([])
  const [selected, setSelected] = usePersistent<string | null>('ondb-file', null)
  const [follow, setFollow] = usePersistent('ondb-follow', true)

  const load = useCallback(async () => {
    const r = await api.files().catch(() => null)
    if (!r) return
    setFiles(r.files)
    setSelected(p => (p && r.files.some(f => f.path === p) ? p : (r.files.find(f => f.path.endsWith('app.zig'))?.path ?? r.files[0]?.path ?? null)))
  }, [setSelected])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    if (conn === 'live') load()
  }, [conn, load])

  useEffect(() => {
    return onFilesChanged((ev: FilesChangedEvent) => {
      const ts = ev.ts_ms || Date.now()
      setFiles(prev => {
        const map = new Map(prev.map(f => [f.path, f]))
        for (const c of ev.changes) {
          if (c.kind === 'removed') {
            map.delete(c.path)
          } else {
            map.set(c.path, {
              path: c.path,
              bytes: c.bytes,
              lines: c.lines,
              changed_ms: ts,
              kind: c.kind,
            })
          }
        }
        return [...map.values()].sort((a, b) => a.path.localeCompare(b.path))
      })
    })
  }, [onFilesChanged])

  const head = fileFeed[0]
  useEffect(() => {
    if (!head || !follow) return
    if (head.act.source !== 'agent' || head.act.kind === 'removed') return
    setSelected(head.path)
  }, [head, follow, setSelected])

  const create = async (p: string) => {
    const ok = await run('Could not create file', () => api.writeFile(p, ''))
    if (ok) {
      setSelected(p)
    }
  }

  const ingest = async () => {
    const r = await run('Ingest failed', () => api.ingest())
    if (r) toast(r.ingested ? 'Ingested disk changes' : 'Disk already in sync', { description: r.ingested ? 'External edits became a new causal batch.' : 'No drift between disk and the CRDT tree.' })
    refreshInfo()
  }

  return (
    <div className="@container h-full min-h-0">
      <div className="flex h-full min-h-0 flex-col @[560px]:flex-row">
        <div className="flex max-h-[40%] min-h-0 shrink-0 flex-col border-b border-border @[560px]:max-h-none @[560px]:w-[232px] @[560px]:border-r @[560px]:border-b-0">
          <div className="min-h-0 flex-1">
            <FileTree files={files} selected={selected} onSelect={setSelected} activity={fileActivity} onCreate={create} onIngest={ingest} />
          </div>
          <div className="hidden shrink-0 border-t border-border @[560px]:block">
            <div className="flex items-center gap-1.5 px-3 pt-2 pb-1 text-[11px] text-muted-foreground">
              <span className="relative flex size-1.5">
                <span className={cn('absolute inset-0 rounded-full bg-ok/60', head && Date.now() - head.act.ts < 4000 && 'animate-ping')} />
                <span className="relative size-1.5 rounded-full bg-ok" />
              </span>
              Live activity
              <Tip label={follow ? 'Following agent edits — the viewer jumps to each file it touches' : 'Follow agent edits'}>
                <button onClick={() => setFollow(f => !f)} className={cn('ml-auto flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[10.5px] transition', follow ? 'bg-primary/10 text-primary' : 'hover:bg-accent')}>
                  <Crosshair className="size-3" /> follow
                </button>
              </Tip>
            </div>
            <div className="flex h-[92px] flex-col gap-px overflow-hidden px-1.5 pb-2">
              {fileFeed.slice(0, 4).map((f, i) => (
                <button key={`${f.path}-${f.act.ts}-${i}`} onClick={() => setSelected(f.path)} className="flex h-[22px] shrink-0 items-center gap-1.5 rounded px-1.5 text-left text-[11px] text-muted-foreground animate-rise hover:bg-accent hover:text-foreground">
                  <FileIcon path={f.path} className="size-3" />
                  <span className="min-w-0 flex-1 truncate">{f.path.split('/').at(-1)}</span>
                  <span className="font-mono text-[10px] tabular">
                    {f.act.added ? <span className="text-ok">+{f.act.added}</span> : null}
                    {f.act.removed ? <span className="ml-0.5 text-destructive">−{f.act.removed}</span> : null}
                  </span>
                  <span className="w-7 shrink-0 text-right text-[10px] opacity-70">{ago(f.act.ts)}</span>
                </button>
              ))}
              {!fileFeed.length ? <div className="px-1.5 py-2 text-[11px] text-muted-foreground/70">Waiting for the next write…</div> : null}
            </div>
          </div>
        </div>
        <div className="min-h-0 min-w-0 flex-1">
          {selected ? (
            <FileViewer key={selected} path={selected} activity={fileActivity[selected]} />
          ) : (
            <div className="flex h-full flex-col items-center justify-center gap-2 text-muted-foreground">
              <FolderTree className="size-5" />
              <span className="text-[12.5px]">Pick a file</span>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
