const CONTROL_AND_SPACE = /[\u0000-\u0020\u007f]+/g
const SCHEME_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*):/
const ALLOWED_SCHEMES = new Set(['http', 'https', 'mailto'])

export function sanitizeUrl(raw: string | null | undefined): string | null {
  if (typeof raw !== 'string') return null
  const trimmed = raw.trim()
  if (!trimmed) return null
  const normalized = trimmed.replace(CONTROL_AND_SPACE, '')
  if (!normalized) return null
  if (normalized.startsWith('#')) return trimmed
  if (normalized.startsWith('/')) {
    if (normalized.startsWith('//') || normalized.startsWith('/\\')) return null
    return trimmed
  }
  const m = SCHEME_RE.exec(normalized)
  if (!m) return null
  const scheme = m[1].toLowerCase()
  if (!ALLOWED_SCHEMES.has(scheme)) return null
  return trimmed
}
