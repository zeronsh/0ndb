import { memo, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ArrowDown, ArrowUp } from 'lucide-react'
import { highlight } from '@/lib/highlight'

function escapeHtml(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function plainHtml(code: string) {
  return `<pre class="shiki"><code>${code
    .split('\n')
    .map(l => `<span class="line">${escapeHtml(l)}</span>`)
    .join('\n')}</code></pre>`
}

export const CodeView = memo(function CodeView({ code, lang, changed, flashKey }: { code: string; lang: string | null; changed: number[]; flashKey: number }) {
  const [html, setHtml] = useState(() => plainHtml(code))
  const host = useRef<HTMLDivElement>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const [offscreen, setOffscreen] = useState<'above' | 'below' | null>(null)

  useEffect(() => {
    let alive = true
    if (!lang) {
      setHtml(plainHtml(code))
      return
    }
    highlight(code, lang)
      .then(h => alive && setHtml(h ?? plainHtml(code)))
      .catch(() => alive && setHtml(plainHtml(code)))
    return () => {
      alive = false
    }
  }, [code, lang])

  useLayoutEffect(() => {
    const el = host.current
    if (!el) return
    const lines = el.querySelectorAll<HTMLElement>('.line')
    const set = new Set(changed)
    const toFlash: HTMLElement[] = []
    lines.forEach((ln, i) => {
      const hit = set.has(i)
      ln.classList.toggle('is-recent', hit)
      if (ln.classList.contains('is-changed')) ln.classList.remove('is-changed')
      if (hit && flashKey) toFlash.push(ln)
    })
    if (toFlash.length) {
      void el.offsetWidth
      for (const ln of toFlash) ln.classList.add('is-changed')
    }
    const sc = scroller.current
    if (!sc || !changed.length || !flashKey) {
      setOffscreen(null)
      return
    }
    const first = lines[changed[0]]
    if (!first) return
    const top = first.offsetTop
    if (top < sc.scrollTop) setOffscreen('above')
    else if (top > sc.scrollTop + sc.clientHeight - 24) setOffscreen('below')
    else setOffscreen(null)
  }, [html, changed, flashKey])

  const jump = () => {
    const el = host.current?.querySelectorAll<HTMLElement>('.line')[changed[0]]
    const sc = scroller.current
    if (el && sc) sc.scrollTo({ top: el.offsetTop - sc.clientHeight / 3, behavior: 'smooth' })
    setOffscreen(null)
  }

  const n = code.split('\n').length
  return (
    <div className="relative h-full min-h-0">
      <div
        ref={scroller}
        onScroll={() => offscreen && setOffscreen(null)}
        className="code-view absolute inset-0 overflow-auto font-mono text-[12.5px] leading-[20px]"
      >
        <div className="flex min-w-max py-3">
          <div className="sticky left-0 z-[1] shrink-0 bg-background pr-1 pl-4 text-right text-muted-foreground/50 select-none tabular">
            {Array.from({ length: n }, (_, i) => (
              <div key={i} className={changed.includes(i) ? 'text-ok' : undefined}>
                {i + 1}
              </div>
            ))}
          </div>
          <div ref={host} className="min-w-0 flex-1 [&_pre]:!bg-transparent [&_pre]:outline-none" dangerouslySetInnerHTML={{ __html: html }} />
        </div>
      </div>
      <div className={`pointer-events-none absolute inset-x-0 flex justify-center transition-all duration-200 ${offscreen === 'above' ? 'top-3' : 'bottom-3'} ${offscreen ? 'opacity-100' : 'translate-y-1 opacity-0'}`}>
        <button onClick={jump} className="pointer-events-auto inline-flex items-center gap-1.5 rounded-full border border-border bg-background py-1 pr-3 pl-2 text-[11.5px] text-muted-foreground shadow-sm hover:text-foreground">
          {offscreen === 'above' ? <ArrowUp className="size-3 text-ok" /> : <ArrowDown className="size-3 text-ok" />}
          {changed.length} line{changed.length === 1 ? '' : 's'} changed {offscreen ?? ''}
        </button>
      </div>
    </div>
  )
})
