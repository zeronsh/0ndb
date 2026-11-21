import type { HighlighterCore } from 'shiki/core'

const LANGS: Record<string, () => Promise<unknown>> = {
  zig: () => import('shiki/langs/zig.mjs'),
  ts: () => import('shiki/langs/typescript.mjs'),
  tsx: () => import('shiki/langs/tsx.mjs'),
  js: () => import('shiki/langs/javascript.mjs'),
  jsx: () => import('shiki/langs/jsx.mjs'),
  json: () => import('shiki/langs/json.mjs'),
  bash: () => import('shiki/langs/bash.mjs'),
  rust: () => import('shiki/langs/rust.mjs'),
  python: () => import('shiki/langs/python.mjs'),
  go: () => import('shiki/langs/go.mjs'),
  c: () => import('shiki/langs/c.mjs'),
  css: () => import('shiki/langs/css.mjs'),
  html: () => import('shiki/langs/html.mjs'),
  markdown: () => import('shiki/langs/markdown.mjs'),
  yaml: () => import('shiki/langs/yaml.mjs'),
  toml: () => import('shiki/langs/toml.mjs'),
  diff: () => import('shiki/langs/diff.mjs'),
}

const ALIASES: Record<string, string> = {
  typescript: 'ts',
  javascript: 'js',
  mjs: 'js',
  cjs: 'js',
  sh: 'bash',
  shell: 'bash',
  zsh: 'bash',
  console: 'bash',
  py: 'python',
  rs: 'rust',
  md: 'markdown',
  yml: 'yaml',
  h: 'c',
  htm: 'html',
  patch: 'diff',
}

export function resolveLang(lang?: string | null): string | null {
  if (!lang) return null
  const l = lang.toLowerCase()
  const key = ALIASES[l] ?? l
  return LANGS[key] ? key : null
}

export function langFromPath(path: string): string | null {
  const ext = path.split('.').at(-1)?.toLowerCase() ?? ''
  return resolveLang(ext)
}

let core: Promise<HighlighterCore> | null = null
const loaded = new Set<string>()
const MAX_CACHE_ENTRIES = 64
const MAX_CACHE_CHARS = 4 * 1024 * 1024
const cache = new Map<string, string>()
let cacheChars = 0

function hashContent(code: string): string {
  let h1 = 0x811c9dc5
  let h2 = 0x01000193
  for (let i = 0; i < code.length; i++) {
    const ch = code.charCodeAt(i)
    h1 ^= ch
    h1 = Math.imul(h1, 0x01000193)
    h2 ^= ch ^ (i & 0xff)
    h2 = Math.imul(h2, 0x85ebca6b)
  }
  return `${code.length}:${(h1 >>> 0).toString(16)}:${(h2 >>> 0).toString(16)}`
}

function cacheGet(key: string): string | undefined {
  const hit = cache.get(key)
  if (hit === undefined) return undefined
  cache.delete(key)
  cache.set(key, hit)
  return hit
}

function cacheSet(key: string, html: string) {
  if (html.length > MAX_CACHE_CHARS) return
  const prev = cache.get(key)
  if (prev !== undefined) {
    cacheChars -= prev.length
    cache.delete(key)
  }
  while (cache.size >= MAX_CACHE_ENTRIES || cacheChars + html.length > MAX_CACHE_CHARS) {
    const oldest = cache.keys().next().value
    if (oldest === undefined) break
    const val = cache.get(oldest)
    if (val !== undefined) cacheChars -= val.length
    cache.delete(oldest)
  }
  cache.set(key, html)
  cacheChars += html.length
}

function highlighter() {
  core ??= (async () => {
    const [{ createHighlighterCore }, { createJavaScriptRegexEngine }, light, dark] = await Promise.all([
      import('shiki/core'),
      import('shiki/engine/javascript'),
      import('shiki/themes/github-light-default.mjs'),
      import('shiki/themes/github-dark-default.mjs'),
    ])
    return createHighlighterCore({
      themes: [light.default, dark.default],
      langs: [],
      engine: createJavaScriptRegexEngine({ forgiving: true }),
    })
  })()
  return core
}

export async function highlight(code: string, lang: string): Promise<string | null> {
  const key = resolveLang(lang)
  if (!key) return null
  const ck = `${key}:${hashContent(code)}`
  const hit = cacheGet(ck)
  if (hit) return hit
  const hl = await highlighter()
  if (!loaded.has(key)) {
    const mod = (await LANGS[key]()) as { default: Parameters<HighlighterCore['loadLanguage']>[0] }
    await hl.loadLanguage(mod.default)
    loaded.add(key)
  }
  const id = key === 'ts' ? 'typescript' : key === 'js' ? 'javascript' : key
  const html = hl.codeToHtml(code, {
    lang: hl.getLoadedLanguages().includes(id) ? id : key,
    themes: { light: 'github-light-default', dark: 'github-dark-default' },
    defaultColor: 'light',
  })
  cacheSet(ck, html)
  return html
}
