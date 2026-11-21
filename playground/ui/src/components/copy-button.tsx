import { useState, type ReactNode } from 'react'
import { Check, Copy } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Tip } from './ui/tooltip'

export function CopyButton({ text, label = 'Copy', className, icon, children }: { text: string; label?: string; className?: string; icon?: ReactNode; children?: ReactNode }) {
  const [state, setState] = useState<'' | 'copied' | 'failed'>('')
  const onClick = async (e: React.MouseEvent) => {
    e.stopPropagation()
    try {
      await navigator.clipboard.writeText(text)
      setState('copied')
    } catch {
      setState('failed')
    }
    setTimeout(() => setState(''), 1400)
  }
  return (
    <Tip label={state === 'copied' ? 'Copied' : state === 'failed' ? 'Clipboard unavailable' : label}>
      <button
        type="button"
        onClick={onClick}
        aria-label={label}
        className={cn('inline-flex h-6 min-w-6 items-center justify-center gap-1 rounded-md px-1 text-[11.5px] text-muted-foreground transition hover:bg-accent hover:text-foreground', className)}
      >
        {state === 'copied' ? <Check className="size-3.5 text-ok" /> : (icon ?? <Copy className="size-3.5" />)}
        {children}
      </button>
    </Tip>
  )
}
