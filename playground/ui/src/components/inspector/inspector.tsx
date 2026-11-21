import { useCallback, useRef } from 'react'
import { Boxes, FolderTree, GitGraph, RadioTower } from 'lucide-react'
import type { Message } from '@/lib/api'
import { usePersistent } from '@/lib/theme'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../ui/tabs'
import { FileExplorer } from '../files/file-explorer'
import { HistoryPanel } from './history-panel'
import { SyncPanel } from './sync-panel'
import { HarnessPanel } from './harness-panel'

export type InspectorTab = 'workspace' | 'history' | 'sync' | 'harnesses'

export function Inspector({ tab, setTab, diffMsg, setDiffMsg }: { tab: InspectorTab; setTab: (t: InspectorTab) => void; diffMsg: Message | null; setDiffMsg: (m: Message | null) => void }) {
  const [width, setWidth] = usePersistent('ondb-inspector-w2', 660)
  const drag = useRef<{ x: number; w: number } | null>(null)
  const onDown = useCallback(
    (e: React.PointerEvent) => {
      drag.current = { x: e.clientX, w: width }
      ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    },
    [width],
  )
  const onMove = (e: React.PointerEvent) => {
    if (!drag.current) return
    setWidth(Math.min(1100, Math.max(360, drag.current.w + drag.current.x - e.clientX)))
  }
  const onUp = () => {
    drag.current = null
  }

  return (
    <aside className="relative flex h-full shrink-0 flex-col border-l border-border bg-background" style={{ width }}>
      <div onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} className="group absolute inset-y-0 -left-1 z-10 w-2 cursor-col-resize">
        <span className="absolute inset-y-0 left-1 w-px bg-transparent transition-colors group-hover:bg-ring/50" />
      </div>
      <Tabs value={tab} onValueChange={v => setTab(v as InspectorTab)} className="flex h-full min-h-0 flex-col">
        <div className="flex h-14 shrink-0 items-center border-b border-border px-3">
          <TabsList className="w-full">
            <TabsTrigger value="workspace"><FolderTree />Files</TabsTrigger>
            <TabsTrigger value="history"><GitGraph />History</TabsTrigger>
            <TabsTrigger value="sync"><RadioTower />Sync</TabsTrigger>
            <TabsTrigger value="harnesses"><Boxes />Harnesses</TabsTrigger>
          </TabsList>
        </div>
        <TabsContent value="workspace" className="min-h-0 flex-1">
          <FileExplorer />
        </TabsContent>
        <TabsContent value="history" className="min-h-0 flex-1">
          <HistoryPanel diffMsg={diffMsg} setDiffMsg={setDiffMsg} />
        </TabsContent>
        <TabsContent value="sync" className="min-h-0 flex-1">
          <SyncPanel />
        </TabsContent>
        <TabsContent value="harnesses" className="min-h-0 flex-1">
          <HarnessPanel />
        </TabsContent>
      </Tabs>
    </aside>
  )
}
