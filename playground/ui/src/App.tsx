import { useCallback, useEffect, useRef, useState } from 'react'
import { Toaster } from 'sonner'
import type { Message } from '@/lib/api'
import { StoreProvider, useStore } from '@/lib/store'
import { usePersistent, useTheme } from '@/lib/theme'
import { Sidebar } from '@/components/sidebar'
import { ThreadView } from '@/components/thread/thread-view'
import { Inspector, type InspectorTab } from '@/components/inspector/inspector'
import { CommandPalette } from '@/components/command-palette'
import type { ComposerHandle } from '@/components/thread/composer'
import { TooltipProvider } from '@/components/ui/tooltip'

function Shell() {
  const { pref, setPref } = useTheme()
  const { createSession, active } = useStore()
  const [sidebarOpen, setSidebarOpen] = usePersistent('ondb-sidebar', true)
  const [inspectorOpen, setInspectorOpen] = usePersistent('ondb-inspector', true)
  const [tab, setTab] = usePersistent<InspectorTab>('ondb-inspector-tab', 'workspace')
  const [diffMsg, setDiffMsg] = useState<Message | null>(null)
  const [palette, setPalette] = useState(false)
  const composer = useRef<ComposerHandle>(null)

  useEffect(() => setDiffMsg(null), [active?.thread_id])

  const openTab = useCallback(
    (t: InspectorTab) => {
      setTab(t)
      setInspectorOpen(true)
    },
    [setTab, setInspectorOpen],
  )

  const showChanges = useCallback(
    (m: Message) => {
      setDiffMsg(m)
      openTab('history')
    },
    [openTab],
  )

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey
      if (!mod) return
      if (e.key === 'k') {
        e.preventDefault()
        setPalette(p => !p)
      } else if (e.key === 'b' || e.key === 'B') {
        e.preventDefault()
        setSidebarOpen(o => !o)
      } else if (e.key === '.') {
        e.preventDefault()
        setInspectorOpen(o => !o)
      } else if (e.key === '/') {
        e.preventDefault()
        composer.current?.openPicker()
      } else if (e.shiftKey && (e.key === 'o' || e.key === 'O')) {
        e.preventDefault()
        createSession('New session', active?.provider ?? 'mock', active ? active.model : 'sim-native-v1')
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [setSidebarOpen, setInspectorOpen, createSession, active])

  return (
    <div className="flex h-full w-full overflow-hidden bg-sidebar">
      <div
        aria-hidden={!sidebarOpen}
        className={`flex shrink-0 overflow-hidden transition-[width,opacity] duration-200 ease-out ${sidebarOpen ? 'w-[256px] opacity-100' : 'pointer-events-none w-0 opacity-0'}`}
      >
        <Sidebar onSearch={() => setPalette(true)} theme={pref} setTheme={setPref} />
      </div>
      <main className="flex min-w-0 flex-1 bg-background">
        <ThreadView
          composerRef={composer}
          onShowChanges={showChanges}
          sidebarOpen={sidebarOpen}
          onToggleSidebar={() => setSidebarOpen(o => !o)}
          inspectorOpen={inspectorOpen}
          onToggleInspector={() => setInspectorOpen(o => !o)}
        />
      </main>
      {inspectorOpen ? (
        <div className="hidden lg:flex">
          <Inspector tab={tab} setTab={setTab} diffMsg={diffMsg} setDiffMsg={setDiffMsg} />
        </div>
      ) : null}
      <CommandPalette
        open={palette}
        setOpen={setPalette}
        openTab={openTab}
        toggleSidebar={() => setSidebarOpen(o => !o)}
        toggleInspector={() => setInspectorOpen(o => !o)}
        setTheme={setPref}
        openPicker={() => composer.current?.openPicker()}
      />
    </div>
  )
}

export default function App() {
  return (
    <TooltipProvider>
      <StoreProvider>
        <Shell />
        <Toaster
          position="bottom-right"
          toastOptions={{
            classNames: {
              toast: '!rounded-xl !border !border-border !bg-popover !text-popover-foreground !shadow-pop !font-sans !text-[13px]',
              description: '!text-muted-foreground !text-[12px]',
            },
          }}
        />
      </StoreProvider>
    </TooltipProvider>
  )
}
