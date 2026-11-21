export interface AnsiStyle {
  fg?: number | string
  bg?: number | string
  bold?: boolean
  dim?: boolean
  italic?: boolean
  underline?: boolean
  strike?: boolean
  inverse?: boolean
}

export interface AnsiSpan {
  text: string
  style: AnsiStyle | null
}

const PALETTE_256: string[] = (() => {
  const out: string[] = []
  for (let i = 0; i < 16; i++) out.push('')
  const steps = [0, 95, 135, 175, 215, 255]
  for (let r = 0; r < 6; r++) for (let g = 0; g < 6; g++) for (let b = 0; b < 6; b++) out.push(`rgb(${steps[r]},${steps[g]},${steps[b]})`)
  for (let i = 0; i < 24; i++) {
    const v = 8 + i * 10
    out.push(`rgb(${v},${v},${v})`)
  }
  return out
})()

function applySgr(style: AnsiStyle, params: number[]): AnsiStyle {
  const s: AnsiStyle = { ...style }
  const p = params.length ? params : [0]
  for (let i = 0; i < p.length; i++) {
    const n = p[i]
    if (n === 0 || Number.isNaN(n)) for (const k of Object.keys(s) as (keyof AnsiStyle)[]) delete s[k]
    else if (n === 1) s.bold = true
    else if (n === 2) s.dim = true
    else if (n === 3) s.italic = true
    else if (n === 4) s.underline = true
    else if (n === 7) s.inverse = true
    else if (n === 9) s.strike = true
    else if (n === 21 || n === 22) {
      delete s.bold
      delete s.dim
    } else if (n === 23) delete s.italic
    else if (n === 24) delete s.underline
    else if (n === 27) delete s.inverse
    else if (n === 29) delete s.strike
    else if (n >= 30 && n <= 37) s.fg = n - 30
    else if (n >= 90 && n <= 97) s.fg = n - 90 + 8
    else if (n === 39) delete s.fg
    else if (n >= 40 && n <= 47) s.bg = n - 40
    else if (n >= 100 && n <= 107) s.bg = n - 100 + 8
    else if (n === 49) delete s.bg
    else if (n === 38 || n === 48) {
      const key = n === 38 ? 'fg' : 'bg'
      if (p[i + 1] === 5 && p[i + 2] != null) {
        const c = p[i + 2]
        s[key] = c < 16 ? c : PALETTE_256[c]
        i += 2
      } else if (p[i + 1] === 2 && p[i + 4] != null) {
        s[key] = `rgb(${p[i + 2]},${p[i + 3]},${p[i + 4]})`
        i += 4
      }
    }
  }
  return s
}

export function parseAnsi(input: string): AnsiSpan[][] {
  const text = String(input ?? '').replace(/\r\n/g, '\n')
  const lines: AnsiSpan[][] = []
  let style: AnsiStyle = {}
  let spans: AnsiSpan[] = []
  let buf = ''
  const snapshot = () => (Object.keys(style).length ? style : null)
  const flush = () => {
    if (!buf) return
    const st = snapshot()
    const last = spans.at(-1)
    if (last && last.style === st) last.text += buf
    else spans.push({ text: buf, style: st })
    buf = ''
  }
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '\x1b') {
      const next = text[i + 1]
      if (next === '[') {
        let j = i + 2
        while (j < text.length && !/[@-~]/.test(text[j])) j++
        if (text[j] === 'm' && !/[<=>?]/.test(text[i + 2] ?? '')) {
          flush()
          const raw = text.slice(i + 2, j)
          style = applySgr(style, raw === '' ? [] : raw.split(/[;:]/).map(x => (x === '' ? 0 : Number(x))))
        }
        i = j
      } else if (next === ']' || next === 'P' || next === '_' || next === '^') {
        let j = i + 2
        while (j < text.length && text[j] !== '\x07' && !(text[j] === '\x1b' && text[j + 1] === '\\')) j++
        i = text[j] === '\x07' ? j : j + 1
      } else i += 1
      continue
    }
    if (c === '\n') {
      flush()
      lines.push(spans)
      spans = []
      continue
    }
    if (c === '\r') {
      buf = ''
      spans = []
      continue
    }
    if (c === '\t') {
      buf += '    '
      continue
    }
    const code = c.charCodeAt(0)
    if (code < 0x20 || code === 0x7f) continue
    buf += c
  }
  flush()
  lines.push(spans)
  while (lines.length > 1 && lines.at(-1)!.length === 0) lines.pop()
  return lines
}

export function stripAnsi(input: string) {
  return parseAnsi(input)
    .map(l => l.map(s => s.text).join(''))
    .join('\n')
}

export function spanProps(style: AnsiStyle | null): { className?: string; style?: React.CSSProperties } | null {
  if (!style) return null
  let { fg, bg } = style
  if (style.inverse) [fg, bg] = [bg ?? 'var(--term)', fg ?? 'var(--term-foreground)']
  const cls: string[] = []
  const css: React.CSSProperties = {}
  if (typeof fg === 'number') cls.push(`ansi-fg${fg}`)
  else if (fg) css.color = fg
  if (typeof bg === 'number') css.background = `color-mix(in oklab, currentColor 18%, transparent)`
  else if (bg) css.background = bg
  if (style.bold) cls.push('ansi-b')
  if (style.dim) cls.push('ansi-dim')
  if (style.italic) cls.push('ansi-i')
  if (style.underline) cls.push('ansi-u')
  if (style.strike) cls.push('ansi-s')
  return { className: cls.join(' ') || undefined, style: Object.keys(css).length ? css : undefined }
}
