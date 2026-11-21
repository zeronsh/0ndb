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
const cache = new Map<string, string>()

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
  const ck = `${key}\u0000${code}`
  const hit = cache.get(ck)
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
  if (cache.size > 400) cache.clear()
  cache.set(ck, html)
  return html
}
