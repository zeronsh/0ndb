export const ACTOR_STYLE: Record<string, { dot: string; chip: string; label: string }> = {
  seed: { dot: 'bg-violet', chip: 'bg-violet-soft text-violet', label: 'seed' },
  agent: { dot: 'bg-primary', chip: 'bg-primary/10 text-primary', label: 'agent' },
  disk: { dot: 'bg-amber', chip: 'bg-amber-soft text-amber', label: 'disk' },
  editor: { dot: 'bg-ok', chip: 'bg-ok-soft text-ok', label: 'editor' },
}

export function actorStyle(label?: string) {
  return ACTOR_STYLE[label ?? ''] ?? { dot: 'bg-muted-foreground', chip: 'bg-muted text-muted-foreground', label: label || 'actor' }
}
