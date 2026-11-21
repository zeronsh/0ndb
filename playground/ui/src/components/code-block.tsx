import { memo, useEffect, useState } from 'react'
import { highlight, resolveLang } from '@/lib/highlight'
import { cn } from '@/lib/utils'
import { CopyButton } from './copy-button'

export const Highlighted = memo(function Highlighted({ code, lang, className }: { code: string; lang: string | null; className?: string }) {
  const [html, setHtml] = useState<string | null>(null)
  useEffect(() => {
    let alive = true
    if (!lang || !resolveLang(lang)) {
      setHtml(null)
      return
    }
    const t = setTimeout(() => {
      highlight(code, lang)
        .then(h => alive && setHtml(h))
        .catch(() => alive && setHtml(null))
    }, 30)
    return () => {
      alive = false
      clearTimeout(t)
    }
  }, [code, lang])
  if (html) return <div className={cn('[&_pre]:font-mono [&_pre]:outline-none', className)} dangerouslySetInnerHTML={{ __html: html }} />
  return (
    <pre className={cn('font-mono', className)}>
      <code>{code}</code>
    </pre>
  )
})

export function CodeBlock({ code, lang }: { code: string; lang: string | null }) {
  return (
    <div className="group/code relative my-1 overflow-hidden rounded-xl border border-hairline bg-term">
      <div className="flex h-8 items-center justify-between border-b border-hairline pr-1.5 pl-3">
        <span className="font-mono text-[11px] text-faint">{lang || 'text'}</span>
        <CopyButton text={code} label="Copy code" className="opacity-70 group-hover/code:opacity-100" />
      </div>
      <Highlighted code={code.replace(/\n$/, '')} lang={lang} className="overflow-x-auto px-3.5 py-3 text-[12.5px] leading-[1.65] text-term-foreground [&_pre]:min-w-max" />
    </div>
  )
}
