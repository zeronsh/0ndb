import * as React from 'react'
import { Tabs as TabsPrimitive } from 'radix-ui'
import { cn } from '@/lib/utils'

export const Tabs = TabsPrimitive.Root

export function TabsList({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.List>) {
  return <TabsPrimitive.List className={cn('inline-flex h-8 items-center gap-0.5 rounded-lg bg-muted p-0.5 text-muted-foreground', className)} {...props} />
}

export function TabsTrigger({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.Trigger>) {
  return (
    <TabsPrimitive.Trigger
      className={cn(
        'inline-flex h-7 flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-md px-2.5 text-[12.5px] font-medium transition-all duration-150 outline-none hover:text-foreground focus-visible:ring-[3px] focus-visible:ring-ring/40 disabled:opacity-50 data-[state=active]:bg-background data-[state=active]:text-foreground data-[state=active]:shadow-[0_1px_2px_oklch(0_0_0/0.08),0_0_0_1px_var(--hairline)] dark:data-[state=active]:bg-card [&_svg]:size-3.5 [&_svg]:shrink-0',
        className,
      )}
      {...props}
    />
  )
}

export function TabsContent({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.Content>) {
  return <TabsPrimitive.Content className={cn('outline-none', className)} {...props} />
}
