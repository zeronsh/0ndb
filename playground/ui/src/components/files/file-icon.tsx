import { Braces, FileCode2, FileText, FileType, Folder, FolderOpen, Hash, Image, Settings2, TerminalSquare, File } from 'lucide-react'
import { cn } from '@/lib/utils'

const EXT: Record<string, { icon: typeof File; hue: number | null }> = {
  zig: { icon: FileCode2, hue: 60 },
  ts: { icon: FileCode2, hue: 240 },
  tsx: { icon: FileCode2, hue: 210 },
  js: { icon: FileCode2, hue: 90 },
  jsx: { icon: FileCode2, hue: 200 },
  rs: { icon: FileCode2, hue: 35 },
  go: { icon: FileCode2, hue: 200 },
  py: { icon: FileCode2, hue: 250 },
  c: { icon: FileCode2, hue: 250 },
  h: { icon: FileCode2, hue: 280 },
  json: { icon: Braces, hue: 85 },
  zon: { icon: Braces, hue: 60 },
  toml: { icon: Settings2, hue: null },
  yaml: { icon: Settings2, hue: null },
  yml: { icon: Settings2, hue: null },
  md: { icon: FileText, hue: 230 },
  txt: { icon: FileText, hue: null },
  css: { icon: Hash, hue: 300 },
  html: { icon: FileType, hue: 25 },
  sh: { icon: TerminalSquare, hue: 150 },
  png: { icon: Image, hue: 330 },
  svg: { icon: Image, hue: 330 },
}

export function FileIcon({ path, className }: { path: string; className?: string }) {
  const ext = path.split('.').at(-1)?.toLowerCase() ?? ''
  const e = EXT[ext] ?? { icon: File, hue: null }
  const Icon = e.icon
  return <Icon className={cn('size-3.5 shrink-0', className)} style={e.hue != null ? { color: `light-dark(oklch(0.55 0.12 ${e.hue}), oklch(0.75 0.11 ${e.hue}))` } : { color: 'var(--muted-foreground)' }} />
}

export function FolderIcon({ open, className }: { open: boolean; className?: string }) {
  const Icon = open ? FolderOpen : Folder
  return <Icon className={cn('size-3.5 shrink-0 text-muted-foreground', className)} />
}
