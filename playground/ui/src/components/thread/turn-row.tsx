import { createContext, useContext, type ReactNode } from 'react'
import { Collapse, definePrimitive, Escape, HStack, Text, useMugenState, VStack } from '@wingleeio/mugen'
import { defineMarkdownComponents, Markdown } from '@wingleeio/mugen-markdown'
import { ChevronLeft, ChevronRight, Copy, FileDiff, GitBranch, Pencil, RotateCcw, AlertTriangle, CircleSlash } from 'lucide-react'
import type { Message, ProviderInfo } from '@/lib/api'
import { modelName, providerName, useCatalogs } from '@/lib/catalog'
import { duration } from '@/lib/format'
import { sanitizeUrl } from '@/lib/sanitize'
import { presentTool, summarizeTools } from '@/lib/tools'
import type { Turn, TurnBlock } from '@/lib/turns'
import { cn } from '@/lib/utils'
import { HarnessGlyph } from '../harness-glyph'
import { CopyButton } from '../copy-button'
import { Tip } from '../ui/tooltip'
import { ToolDetailBox, ToolRowView, TOOL_ROW_H, toolDetailHeight } from './tool-parts'

const SAFE_MD_COMPONENTS = defineMarkdownComponents({
  image: ({ node }) => {
    const safe = sanitizeUrl(node.url)
    if (!safe) return null
    return null
  },
  inline: {
    link: (node, ctx) => {
      const safe = sanitizeUrl(node.url)
      if (!safe) return ctx.runs(node.children)
      return ctx.runs(node.children, {
        href: safe,
        color: ctx.theme.link.color,
        underline: ctx.theme.link.underline ? true : ctx.fmt.underline,
      })
    },
  },
})

const SANS = 'Geist, sans-serif'
const MONO = "'Geist Mono', monospace"

const INK = {
  fg: 'var(--foreground)',
  muted: 'var(--muted-foreground)',
  accent: 'var(--primary)',
  amber: 'var(--amber)',
  hairline: 'color-mix(in oklab, var(--foreground) 12%, transparent)',
  wash: 'color-mix(in oklab, var(--foreground) 5%, transparent)',
} as const

const CHAT_MD_THEME = {
  fontFamily: 'Geist',
  monoFamily: "'Geist Mono', monospace",
  fontSize: 15,
  lineHeight: 26,
  color: INK.fg,
  blockGap: 14,
  heading: { color: INK.fg, weight: 600 },
  link: { color: INK.accent, underline: true },
  inlineCode: { background: INK.wash, color: INK.fg, sizeScale: 0.9 },
  code: {
    background: INK.wash,
    color: INK.fg,
    padding: 14,
    radius: 8,
    fontSize: 13,
    lineHeight: 21,
    header: {
      show: true,
      height: 36,
      fontSize: 12,
      background: 'color-mix(in oklab, var(--foreground) 8%, transparent)',
      color: INK.muted,
      borderColor: INK.hairline,
      buttonBackground: INK.wash,
    },
  },
  blockquote: { borderColor: INK.hairline, color: INK.muted, padding: 12, gap: 8, borderWidth: 2 },
  list: { gap: 8, indent: 22, markerColor: INK.muted },
} as const

const REASONING_MD_THEME = {
  fontFamily: 'Geist',
  monoFamily: "'Geist Mono', monospace",
  fontSize: 14,
  lineHeight: 24,
  color: INK.muted,
  blockGap: 10,
  heading: { color: INK.muted, weight: 600 },
  link: { color: INK.accent, underline: true },
  inlineCode: { background: INK.wash, color: INK.muted, sizeScale: 0.9 },
  code: { background: INK.wash, color: INK.muted, padding: 12, radius: 8, fontSize: 12.5, lineHeight: 19 },
  blockquote: { borderColor: INK.hairline, color: INK.muted, padding: 10, gap: 8, borderWidth: 2 },
  list: { gap: 6, indent: 20, markerColor: INK.muted },
} as const

export interface TurnActions {
  providers: ProviderInfo[]
  busy: boolean
  edit: (msg: Message) => void
  switchTo: (msgId: string, fromId: string) => void
  rollback: (msg: Message) => void
  showChanges: (msg: Message) => void
}

export const TurnCtx = createContext<TurnActions | null>(null)
const useActions = () => useContext(TurnCtx)!

const Disclosure = definePrimitive('button', { name: 'Disclosure' })
const buttonReset = { cursor: 'pointer', textAlign: 'left', background: 'transparent', border: 'none', font: 'inherit', color: 'inherit' } as const
const NO_SHRINK = { flexShrink: 0 } as const

type OpenMap = Record<string, boolean>

export function TurnRow(turn: Turn): ReactNode {
  const [openMap, setOpenMap] = useMugenState<OpenMap>({})
  if (turn.role === 'user') return <UserTurn turn={turn} />
  if (turn.role === 'steer') return <SteerTurn turn={turn} />
  return <AssistantTurn turn={turn} openMap={openMap} setOpenMap={setOpenMap} />
}

function UserTurn({ turn }: { turn: Turn }): ReactNode {
  const sibs = turn.msg.siblings?.length ?? 0
  return (
    <VStack gap={8} padding={16} className="group/row">
      <HStack justify="flex-end">
        <VStack padding={14} style={{ background: 'var(--foreground)', borderRadius: '18px 18px 4px 18px' }}>
          <Text shrink whiteSpace="pre-wrap" font={`15px ${SANS}`} lineHeight={24} color="var(--background)">
            {turn.text}
          </Text>
        </VStack>
      </HStack>
      <HStack justify="flex-end">
        <Escape height={28} width={sibs > 1 ? 148 : 64}>
          <UserActions turn={turn} />
        </Escape>
      </HStack>
    </VStack>
  )
}

function SteerTurn({ turn }: { turn: Turn }): ReactNode {
  return (
    <VStack padding={16}>
      <HStack gap={13} align="stretch">
        <VStack width={2} style={{ background: INK.amber, borderRadius: 2 }} />
        <VStack gap={4}>
          <Text font={`500 12px ${MONO}`} lineHeight={16} color={INK.amber}>
            Steered · interrupt & resume
          </Text>
          <Text font={`15px ${SANS}`} lineHeight={24} color={INK.fg}>
            {turn.text}
          </Text>
        </VStack>
      </HStack>
    </VStack>
  )
}

function AssistantTurn({ turn, openMap, setOpenMap }: { turn: Turn; openMap: OpenMap; setOpenMap: (next: OpenMap) => void }): ReactNode {
  const last = turn.blocks.length - 1
  return (
    <VStack gap={14} padding={16} className="group/row">
      {turn.pending ? (
        <Text font={`600 15px ${SANS}`} lineHeight={26} color={INK.accent} className="animate-pulse">
          ▍
        </Text>
      ) : null}
      {turn.blocks.map((block, i) => (
        <Block key={block.key} block={block} turn={turn} fading={turn.streaming && i === last} openMap={openMap} setOpenMap={setOpenMap} />
      ))}
      {turn.streaming && !turn.pending ? (
        <Text font={`600 15px ${SANS}`} lineHeight={26} color={INK.accent} className="animate-pulse">
          ▍
        </Text>
      ) : null}
      {!turn.streaming ? (
        <Escape height={28}>
          <AssistantActions turn={turn} />
        </Escape>
      ) : null}
    </VStack>
  )
}

function Block({ block, turn, fading, openMap, setOpenMap }: { block: TurnBlock; turn: Turn; fading: boolean; openMap: OpenMap; setOpenMap: (next: OpenMap) => void }): ReactNode {
  if (block.kind === 'markdown') return <Markdown source={block.text} theme={CHAT_MD_THEME} fade={fading} components={SAFE_MD_COMPONENTS} />

  if (block.kind === 'error') {
    return (
      <HStack gap={13} align="stretch">
        <VStack width={2} style={{ background: 'var(--destructive)', borderRadius: 2 }} />
        <Text font={`13px ${MONO}`} lineHeight={20} color="var(--destructive)">
          {block.text}
        </Text>
      </HStack>
    )
  }

  if (block.kind === 'steer') {
    const native = block.steer.mode === 'native'
    const color = native ? INK.accent : INK.amber
    return (
      <HStack gap={13} align="stretch">
        <VStack width={2} style={{ background: color, borderRadius: 2 }} />
        <VStack gap={4}>
          <Text font={`500 12px ${MONO}`} lineHeight={16} color={color}>
            {native ? 'Steered mid-turn · injected natively' : 'Steer received · interrupting to resume'}
          </Text>
          <Text font={`14px ${SANS}`} lineHeight={22} color={INK.fg}>
            {block.steer.prompt}
          </Text>
        </VStack>
      </HStack>
    )
  }

  if (block.kind === 'reasoning') {
    const open = openMap[block.key] ?? !block.done
    const label = block.done ? `Thought${block.seconds ? ` for ${block.seconds}s` : ''}` : 'Thinking…'
    return (
      <VStack>
        <Disclosure padding={2} onClick={() => setOpenMap({ ...openMap, [block.key]: !open })} style={{ ...buttonReset, borderRadius: 6 }}>
          <Text font={`500 12px ${MONO}`} lineHeight={16} color={INK.muted} className={block.done ? undefined : 'text-shimmer'}>
            {label}
          </Text>
        </Disclosure>
        <Collapse id={`reasoning-${block.key}`} open={open}>
          <VStack style={NO_SHRINK}>
            <VStack height={10} />
            <HStack gap={13} align="stretch">
              <VStack width={2} style={{ background: INK.hairline, borderRadius: 2 }} />
              <VStack gap={10}>
                <Markdown source={block.text} theme={REASONING_MD_THEME} fade={fading && !block.done} components={SAFE_MD_COMPONENTS} />
              </VStack>
            </HStack>
          </VStack>
        </Collapse>
      </VStack>
    )
  }

  const views = block.tools.map(t => presentTool(t, turn.streaming))
  const running = views.find(v => v.status === 'running')
  const done = !running
  const open = openMap[block.key] ?? (!done || views.some(v => v.status === 'failed'))
  const label = running ? `${running.progressive} ${running.target}…` : summarizeTools(views)
  return (
    <VStack>
      <Disclosure padding={2} onClick={() => setOpenMap({ ...openMap, [block.key]: !open })} style={{ ...buttonReset, borderRadius: 6 }}>
        <Text font={`500 12px ${MONO}`} lineHeight={16} color={INK.muted} className={running ? 'text-shimmer' : undefined}>
          {label}
        </Text>
      </Disclosure>
      <Collapse id={`tools-${block.key}`} open={open}>
        <VStack style={NO_SHRINK}>
          <VStack height={10} />
          <VStack gap={4}>
            {views.map((v, ti) => {
              const tkey = `${block.key}:${ti}`
              const tOpen = !!openMap[tkey]
              const h = toolDetailHeight(v)
              return (
                <VStack key={tkey}>
                  <Escape height={TOOL_ROW_H}>
                    <ToolRowView view={v} open={tOpen} onToggle={() => setOpenMap({ ...openMap, [block.key]: true, [tkey]: !tOpen })} />
                  </Escape>
                  <Collapse id={`tool-${tkey}`} open={tOpen}>
                    <VStack style={NO_SHRINK}>
                      <VStack height={6} />
                      <Escape height={h}>
                        <ToolDetailBox view={v} height={h} />
                      </Escape>
                      <VStack height={4} />
                    </VStack>
                  </Collapse>
                </VStack>
              )
            })}
          </VStack>
        </VStack>
      </Collapse>
    </VStack>
  )
}

function Switcher({ msg }: { msg: Message }) {
  const a = useActions()
  const n = msg.siblings?.length ?? 0
  if (n < 2) return null
  const i = Math.max(0, msg.sibling_index ?? msg.siblings.indexOf(msg.msg_id))
  return (
    <span className="inline-flex h-7 items-center rounded-lg text-[11.5px] text-muted-foreground">
      <Tip label="Previous branch">
        <button disabled={i === 0 || a.busy} onClick={() => a.switchTo(msg.siblings[i - 1], msg.msg_id)} className="flex size-7 items-center justify-center rounded-lg transition hover:bg-accent hover:text-foreground disabled:opacity-35" aria-label="Previous branch">
          <ChevronLeft className="size-3.5" />
        </button>
      </Tip>
      <span className="flex items-center gap-1 px-0.5 font-mono tabular">
        <GitBranch className="size-3 opacity-60" />
        {i + 1}/{n}
      </span>
      <Tip label="Next branch">
        <button disabled={i === n - 1 || a.busy} onClick={() => a.switchTo(msg.siblings[i + 1], msg.msg_id)} className="flex size-7 items-center justify-center rounded-lg transition hover:bg-accent hover:text-foreground disabled:opacity-35" aria-label="Next branch">
          <ChevronRight className="size-3.5" />
        </button>
      </Tip>
    </span>
  )
}

function IconAction({ label, onClick, disabled, children }: { label: string; onClick: () => void; disabled?: boolean; children: ReactNode }) {
  return (
    <Tip label={label}>
      <button onClick={onClick} disabled={disabled} aria-label={label} className="inline-flex size-7 items-center justify-center rounded-lg text-muted-foreground transition hover:bg-accent hover:text-foreground disabled:opacity-35">
        {children}
      </button>
    </Tip>
  )
}

function UserActions({ turn }: { turn: Turn }) {
  const a = useActions()
  const keep = (turn.msg.siblings?.length ?? 0) > 1
  return (
    <div className={cn('flex h-full items-center justify-end gap-0.5 transition-opacity duration-150 focus-within:opacity-100', keep ? 'opacity-100' : 'opacity-100 md:opacity-0 md:group-hover/row:opacity-100')}>
      <Switcher msg={turn.msg} />
      <CopyButton text={turn.text} label="Copy message" className="size-7 rounded-lg" icon={<Copy className="size-3" />} />
      <IconAction label="Edit & fork from here" onClick={() => a.edit(turn.msg)} disabled={a.busy}>
        <Pencil className="size-3" />
      </IconAction>
    </div>
  )
}

function AssistantActions({ turn }: { turn: Turn }) {
  const a = useActions()
  const catalogs = useCatalogs()
  const m = turn.msg
  const keep = (m.siblings?.length ?? 0) > 1
  return (
    <div className={cn('flex h-full items-center gap-0.5 transition-opacity duration-150 focus-within:opacity-100', keep ? 'opacity-100' : 'opacity-100 md:opacity-0 md:group-hover/row:opacity-100')}>
      <CopyButton text={turn.text} label="Copy response" className="size-7 rounded-lg" icon={<Copy className="size-3" />} />
      <IconAction label="Files this turn changed" onClick={() => a.showChanges(m)}>
        <FileDiff className="size-3" />
      </IconAction>
      <IconAction label="Roll the workspace back to right after this turn" onClick={() => a.rollback(m)} disabled={a.busy}>
        <RotateCcw className="size-3" />
      </IconAction>
      <Switcher msg={m} />
      <span className="ml-1 flex min-w-0 items-center gap-1.5 text-muted-foreground">
        <HarnessGlyph slug={m.provider} size="sm" />
        <span className="truncate text-xs">
          {providerName(m.provider, a.providers)} · {modelName(m.provider, m.model, catalogs[m.provider])}
        </span>
        {m.status === 'interrupted' ? (
          <span className="flex items-center gap-1 text-xs text-amber">
            <CircleSlash className="size-3" /> interrupted
          </span>
        ) : m.status === 'failed' ? (
          <span className="flex items-center gap-1 text-xs text-destructive">
            <AlertTriangle className="size-3" /> failed
          </span>
        ) : null}
        {turn.elapsed ? <span className="font-mono text-[10.5px] opacity-70 tabular">{duration(turn.elapsed)}</span> : null}
        {turn.usage ? (
          <span className="hidden font-mono text-[10.5px] opacity-70 tabular lg:inline">
            {turn.usage.input_tokens.toLocaleString()}↑ {turn.usage.output_tokens.toLocaleString()}↓
          </span>
        ) : null}
      </span>
    </div>
  )
}
