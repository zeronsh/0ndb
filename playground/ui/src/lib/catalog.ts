import { useSyncExternalStore } from 'react'
import { api, type Catalog, type ModelInfo, type ProviderInfo, type ProviderSlug } from './api'

export type CatalogState = { status: 'idle' | 'loading' | 'ready' | 'error'; catalog: Catalog | null; error?: string }

let catalogs: Record<string, CatalogState> = {}
const listeners = new Set<() => void>()
const emit = () => listeners.forEach(l => l())

function set(slug: string, state: CatalogState) {
  catalogs = { ...catalogs, [slug]: state }
  emit()
}

export function seedCatalogs(all: Partial<Record<ProviderSlug, Catalog>>) {
  const next = { ...catalogs }
  for (const [slug, cat] of Object.entries(all)) if (cat && next[slug]?.status !== 'loading') next[slug] = { status: 'ready', catalog: cat }
  catalogs = next
  emit()
}

export function loadModels(slug: string, refresh = false) {
  const have = catalogs[slug]
  if (have && !refresh && (have.status === 'ready' || have.status === 'loading')) return
  set(slug, { status: 'loading', catalog: have?.catalog ?? null })
  api
    .models(slug, refresh)
    .then(catalog => set(slug, { status: 'ready', catalog }))
    .catch(err => set(slug, { status: 'error', catalog: have?.catalog ?? null, error: String(err?.message ?? err) }))
}

export function useCatalogs() {
  return useSyncExternalStore(
    l => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => catalogs,
  )
}

export const SIMULATOR: ProviderInfo = {
  slug: 'mock',
  name: 'Simulator',
  binary: 'built-in',
  available: true,
  native_steer: true,
  persistent: true,
  resume_session: true,
  fork_at_message: true,
}

const NAMES: Record<ProviderSlug, string> = {
  mock: 'Simulator',
  antigravity: 'Antigravity',
  'claude-code': 'Claude Code',
  codex: 'Codex',
  pi: 'Pi',
  hermes: 'Hermes',
  opencode: 'OpenCode',
  cursor: 'Cursor',
  devin: 'Devin',
  muse: 'Muse',
}

export function providerName(slug: string, providers?: ProviderInfo[]) {
  return NAMES[slug as ProviderSlug] ?? providers?.find(p => p.slug === slug)?.name ?? slug
}

export function defaultModel(state: CatalogState | undefined): ModelInfo | undefined {
  return state?.catalog?.models.find(m => m.is_default)
}

export function modelName(_slug: string, model: string | null | undefined, state: CatalogState | undefined) {
  if (!model) {
    const d = defaultModel(state)
    return d ? d.name : 'Default'
  }
  return state?.catalog?.models.find(m => m.id === model)?.name ?? model
}

export type Readiness = 'ready' | 'setup' | 'missing' | 'checking'

export function readiness(p: ProviderInfo, state: CatalogState | undefined): Readiness {
  if (!p.available) return 'missing'
  if (!state || state.status === 'loading' || state.status === 'idle') return state?.catalog?.models.length ? 'ready' : 'checking'
  if (state.status === 'error') return 'setup'
  if (!state.catalog?.models.length) return 'setup'
  return 'ready'
}

export function steerMode(slug: string, model: string | null | undefined, providers: ProviderInfo[]): 'native' | 'fallback' {
  if (slug === 'mock') return model === 'sim-fallback-v1' ? 'fallback' : 'native'
  return providers.find(p => p.slug === slug)?.native_steer ? 'native' : 'fallback'
}
