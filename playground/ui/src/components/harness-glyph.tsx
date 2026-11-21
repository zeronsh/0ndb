import { FlaskConical } from 'lucide-react'
import { cn } from '@/lib/utils'

const GLYPHS: Record<string, { label: string; hue: number }> = {
  antigravity: { label: 'Ag', hue: 255 },
  'claude-code': { label: 'Cc', hue: 40 },
  codex: { label: 'Cx', hue: 160 },
  pi: { label: 'Pi', hue: 300 },
  hermes: { label: 'He', hue: 85 },
  opencode: { label: 'Oc', hue: 210 },
  cursor: { label: 'Cu', hue: 270 },
  devin: { label: 'Dv', hue: 130 },
  muse: { label: 'Mu', hue: 345 },
}

export function HarnessGlyph({ slug, className, size = 'md', dim }: { slug: string; className?: string; size?: 'sm' | 'md' | 'lg'; dim?: boolean }) {
  const dims = size === 'sm' ? 'size-4 rounded-[5px] text-[8px]' : size === 'lg' ? 'size-7 rounded-lg text-[11px]' : 'size-5 rounded-md text-[9px]'
  if (slug === 'mock') {
    return (
      <span
        className={cn('inline-flex shrink-0 items-center justify-center bg-signal-soft text-signal-foreground ring-1 ring-inset ring-signal/25', dims, dim && 'opacity-45 grayscale', className)}
        aria-hidden
      >
        <FlaskConical className={size === 'sm' ? 'size-2.5' : size === 'lg' ? 'size-4' : 'size-3'} strokeWidth={2.25} />
      </span>
    )
  }
  const g = GLYPHS[slug] ?? { label: slug.slice(0, 2), hue: 260 }
  return (
    <span
      className={cn('inline-flex shrink-0 items-center justify-center font-semibold tracking-[-0.02em] ring-1 ring-inset', dims, dim && 'opacity-45 grayscale', className)}
      style={{
        background: `light-dark(oklch(0.95 0.035 ${g.hue}), oklch(0.3 0.05 ${g.hue}))`,
        color: `light-dark(oklch(0.45 0.12 ${g.hue}), oklch(0.85 0.1 ${g.hue}))`,
        ['--tw-ring-color' as string]: `light-dark(oklch(0.85 0.06 ${g.hue}), oklch(0.42 0.07 ${g.hue}))`,
      }}
      aria-hidden
    >
      {g.label}
    </span>
  )
}
