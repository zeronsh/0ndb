import * as React from 'react'
import { Command as CommandPrimitive } from 'cmdk'
import { Search } from 'lucide-react'
import { cn } from '@/lib/utils'

export function Command({ className, ...props }: React.ComponentProps<typeof CommandPrimitive>) {
  return <CommandPrimitive className={cn('flex size-full flex-col overflow-hidden rounded-[inherit] bg-popover text-popover-foreground', className)} {...props} />
}

export function CommandInput({ className, right, ...props }: React.ComponentProps<typeof CommandPrimitive.Input> & { right?: React.ReactNode }) {
  return (
    <div className="flex h-11 items-center gap-2.5 border-b border-hairline px-3.5">
      <Search className="size-4 shrink-0 text-faint" />
      <CommandPrimitive.Input className={cn('flex h-full w-full bg-transparent text-[13.5px] outline-none placeholder:text-faint disabled:opacity-50', className)} {...props} />
      {right}
    </div>
  )
}

export function CommandList({ className, ...props }: React.ComponentProps<typeof CommandPrimitive.List>) {
  return <CommandPrimitive.List className={cn('max-h-[360px] scroll-py-1.5 overflow-x-hidden overflow-y-auto p-1.5', className)} {...props} />
}

export function CommandEmpty(props: React.ComponentProps<typeof CommandPrimitive.Empty>) {
  return <CommandPrimitive.Empty className="py-8 text-center text-[13px] text-muted-foreground" {...props} />
}

export function CommandGroup({ className, ...props }: React.ComponentProps<typeof CommandPrimitive.Group>) {
  return <CommandPrimitive.Group className={cn('overflow-hidden text-foreground [&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:pt-2 [&_[cmdk-group-heading]]:pb-1.5 [&_[cmdk-group-heading]]:text-[11px] [&_[cmdk-group-heading]]:font-medium [&_[cmdk-group-heading]]:text-faint', className)} {...props} />
}

export function CommandItem({ className, ...props }: React.ComponentProps<typeof CommandPrimitive.Item>) {
  return (
    <CommandPrimitive.Item
      className={cn(
        "relative flex h-9 cursor-default select-none items-center gap-2.5 rounded-lg px-2 text-[13px] outline-none data-[disabled=true]:pointer-events-none data-[disabled=true]:opacity-45 data-[selected=true]:bg-accent data-[selected=true]:text-accent-foreground [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 [&_svg:not([class*='text-'])]:text-muted-foreground",
        className,
      )}
      {...props}
    />
  )
}

export function CommandSeparator({ className, ...props }: React.ComponentProps<typeof CommandPrimitive.Separator>) {
  return <CommandPrimitive.Separator className={cn('-mx-1.5 my-1 h-px bg-hairline', className)} {...props} />
}
