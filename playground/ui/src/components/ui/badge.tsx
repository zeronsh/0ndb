import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const badgeVariants = cva(
  'inline-flex items-center gap-1 whitespace-nowrap rounded-md border px-1.5 h-5 text-[11px] font-medium leading-none tabular [&_svg]:size-3 [&_svg]:shrink-0',
  {
    variants: {
      variant: {
        default: 'border-transparent bg-secondary text-secondary-foreground',
        outline: 'border-border text-muted-foreground',
        signal: 'border-transparent bg-signal-soft text-signal-foreground',
        amber: 'border-transparent bg-amber-soft text-amber',
        ok: 'border-transparent bg-ok-soft text-ok',
        danger: 'border-transparent bg-danger-soft text-destructive',
        violet: 'border-transparent bg-violet-soft text-violet',
        mono: 'border-hairline bg-muted font-mono text-[10.5px] text-muted-foreground',
      },
    },
    defaultVariants: { variant: 'default' },
  },
)

export function Badge({ className, variant, ...props }: React.ComponentProps<'span'> & VariantProps<typeof badgeVariants>) {
  return <span data-slot="badge" className={cn(badgeVariants({ variant }), className)} {...props} />
}
