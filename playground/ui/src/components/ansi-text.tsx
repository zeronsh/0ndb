import { memo, useMemo } from 'react'
import { parseAnsi, spanProps } from '@/lib/ansi'
import { cn } from '@/lib/utils'

export const AnsiText = memo(function AnsiText({ text, className, maxLines }: { text: string; className?: string; maxLines?: number }) {
  const lines = useMemo(() => parseAnsi(text), [text])
  const shown = maxLines ? lines.slice(0, maxLines) : lines
  return (
    <pre className={cn('font-mono whitespace-pre-wrap break-words', className)}>
      {shown.map((spans, i) => (
        <div key={i} className="min-h-[1lh]">
          {spans.map((s, j) => {
            const p = spanProps(s.style)
            return p ? (
              <span key={j} {...p}>
                {s.text}
              </span>
            ) : (
              <span key={j}>{s.text}</span>
            )
          })}
        </div>
      ))}
    </pre>
  )
})

export function lineCount(text: string) {
  return parseAnsi(text).length
}
