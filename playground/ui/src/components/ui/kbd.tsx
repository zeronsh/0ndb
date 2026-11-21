import * as React from 'react'
import { cn } from '@/lib/utils'

export function Kbd({ className, ...props }: React.ComponentProps<'kbd'>) {
  return (
    <kbd
      className={cn(
        'pointer-events-none inline-flex h-[18px] min-w-[18px] select-none items-center justify-center gap-0.5 rounded-[5px] border border-border bg-background px-1 font-sans text-[10.5px] font-medium text-muted-foreground shadow-[0_1px_0_var(--border)] dark:bg-card',
        className,
      )}
      {...props}
    />
  )
}
