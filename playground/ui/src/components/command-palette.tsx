import { Boxes, FolderTree, GitGraph, Monitor, Moon, PanelLeft, PanelRight, Plus, RadioTower, Sun, Cpu } from 'lucide-react'
import { providerName } from '@/lib/catalog'
import { ago } from '@/lib/format'
import { useStore } from '@/lib/store'
import type { ThemePref } from '@/lib/theme'
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandSeparator } from './ui/command'
import { Dialog, DialogContent, DialogTitle } from './ui/dialog'
import { HarnessGlyph } from './harness-glyph'
import { Kbd } from './ui/kbd'
import type { InspectorTab } from './inspector/inspector'

export function CommandPalette({ open, setOpen, openTab, toggleSidebar, toggleInspector, setTheme, openPicker }: { open: boolean; setOpen: (o: boolean) => void; openTab: (t: InspectorTab) => void; toggleSidebar: () => void; toggleInspector: () => void; setTheme: (t: ThemePref) => void; openPicker: () => void }) {
  const { sessions, select, createSession, active, providers } = useStore()
  const go = (fn: () => void) => () => {
    setOpen(false)
    fn()
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent showClose={false} className="max-w-[min(580px,calc(100vw-32px))] overflow-hidden p-0">
        <DialogTitle className="sr-only">Command palette</DialogTitle>
        <Command loop>
          <CommandInput placeholder="Search sessions and commands…" right={<Kbd>esc</Kbd>} />
          <CommandList>
            <CommandEmpty>Nothing matches.</CommandEmpty>
            <CommandGroup heading="Actions">
              <CommandItem onSelect={go(() => createSession('New session', active?.provider ?? 'mock', active ? active.model : 'sim-native-v1'))}>
                <Plus /> New session <Kbd className="ml-auto">⌘⇧O</Kbd>
              </CommandItem>
              <CommandItem onSelect={go(openPicker)}>
                <Cpu /> Switch harness & model <Kbd className="ml-auto">⌘/</Kbd>
              </CommandItem>
              <CommandItem onSelect={go(toggleSidebar)}>
                <PanelLeft /> Toggle sidebar <Kbd className="ml-auto">⌘B</Kbd>
              </CommandItem>
              <CommandItem onSelect={go(toggleInspector)}>
                <PanelRight /> Toggle inspector <Kbd className="ml-auto">⌘.</Kbd>
              </CommandItem>
            </CommandGroup>
            <CommandSeparator />
            <CommandGroup heading="Inspect">
              <CommandItem onSelect={go(() => openTab('workspace'))}><FolderTree /> Workspace files & blame</CommandItem>
              <CommandItem onSelect={go(() => openTab('history'))}><GitGraph /> Turn diffs & causal DAG</CommandItem>
              <CommandItem onSelect={go(() => openTab('sync'))}><RadioTower /> Device B E2EE sync</CommandItem>
              <CommandItem onSelect={go(() => openTab('harnesses'))}><Boxes /> Harness matrix</CommandItem>
            </CommandGroup>
            <CommandSeparator />
            <CommandGroup heading="Sessions">
              {sessions.map(s => (
                <CommandItem key={s.thread_id} value={`${s.title} ${s.thread_id}`} onSelect={go(() => select(s.thread_id))}>
                  <HarnessGlyph slug={s.provider} size="sm" />
                  <span className="truncate">{s.title}</span>
                  <span className="ml-auto shrink-0 text-[11px] text-faint">{providerName(s.provider, providers)} · {ago(s.updated_ms)}</span>
                </CommandItem>
              ))}
            </CommandGroup>
            <CommandSeparator />
            <CommandGroup heading="Theme">
              <CommandItem onSelect={go(() => setTheme('light'))}><Sun /> Light</CommandItem>
              <CommandItem onSelect={go(() => setTheme('dark'))}><Moon /> Dark</CommandItem>
              <CommandItem onSelect={go(() => setTheme('system'))}><Monitor /> System</CommandItem>
            </CommandGroup>
          </CommandList>
        </Command>
      </DialogContent>
    </Dialog>
  )
}
