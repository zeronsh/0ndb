import { useLayoutEffect, useRef, useState } from 'react';
import { Collapse, definePrimitive, Escape, HStack, markPrimitive, Text, useMugenState, VStack } from '@wingleeio/mugen';
import { Markdown } from '@wingleeio/mugen-markdown';
import {
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  ClipboardList,
  Copy,
  Download,
  FilePenLine,
  FileText,
  FolderOpen,
  Globe,
  ListChecks,
  Search,
  ExternalLink,
  GitBranch,
  Loader2,
  Pencil,
  ScrollText,
  SquareTerminal,
  TriangleAlert,
  Wrench,
} from 'lucide-react';

import { MORE_HEIGHT, presentTool, progressiveLabel, ROW_HEIGHT, summarizeTools } from './toolPresentation.js';
import { spanProps } from './ansi.js';
import { blockLayoutFor, blockModelFor, monoCellWidth } from './toolBlock.js';

const SANS = 'Geist, sans-serif';
const MONO = "'Geist Mono', monospace";

const INK = {
  fg: 'var(--fg)',
  muted: 'var(--muted)',
  accent: 'var(--primary)',
  hairline: 'var(--hairline)',
  wash: 'var(--wash)',
};

const MD_THEME = {
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
      height: 34,
      fontSize: 12,
      background: 'var(--wash-strong)',
      color: INK.muted,
      borderColor: INK.hairline,
      buttonBackground: INK.wash,
    },
  },
  blockquote: { borderColor: INK.hairline, color: INK.muted, padding: 12, gap: 8, borderWidth: 2 },
  list: { gap: 8, indent: 22, markerColor: INK.muted },
};

// Match zeronsh/chat's measured reasoning aside, using this site's palette.
const REASONING_MD_THEME = {
  ...MD_THEME,
  fontSize: 14,
  lineHeight: 24,
  color: INK.muted,
  blockGap: 10,
  heading: { color: INK.muted, weight: 600 },
  inlineCode: { background: INK.wash, color: INK.muted, sizeScale: 0.9 },
  code: { background: INK.wash, color: INK.muted, padding: 12, radius: 8, fontSize: 12.5, lineHeight: 19 },
  blockquote: { borderColor: INK.hairline, color: INK.muted, padding: 10, gap: 8, borderWidth: 2 },
  list: { gap: 6, indent: 20, markerColor: INK.muted },
};

/** Row callbacks, set by the app (rows only receive their item). */
export const handlers = {
  edit: () => {},
  switchTo: () => {},
  inspect: () => {},
};

const Disclosure = definePrimitive('button', { name: 'Disclosure' });
const buttonReset = { cursor: 'pointer', textAlign: 'left', justifyContent: 'flex-start', alignSelf: 'flex-start', background: 'transparent', border: 'none', font: 'inherit', color: 'inherit' };
const NO_SHRINK = { flexShrink: 0 };

export function TurnRow(turn) {
  const [open, setOpen] = useMugenState(null);
  const [toolOpen, setToolOpen] = useMugenState({});
  const [reasoningOpen, setReasoningOpen] = useMugenState({});
  if (turn.kind === 'user') return <UserTurn turn={turn} />;
  return <AssistantTurn turn={turn} open={open} setOpen={setOpen} reasoningOpen={reasoningOpen} setReasoningOpen={setReasoningOpen} toolOpen={toolOpen} setToolOpen={setToolOpen} />;
}

function Switcher({ turn }) {
  if (!turn.siblings || turn.siblings.length < 2) return null;
  const n = turn.siblings.length;
  const i = turn.siblingIndex;
  return (
    <div className="switcher" title="Alternative branches from here">
      <button disabled={i === 0} onClick={() => handlers.switchTo(turn.siblings[i - 1], turn.id)} aria-label="Previous branch">
        <ChevronLeft size={13} />
      </button>
      <span>
        {i + 1}/{n}
      </span>
      <button disabled={i === n - 1} onClick={() => handlers.switchTo(turn.siblings[i + 1], turn.id)} aria-label="Next branch">
        <ChevronRight size={13} />
      </button>
    </div>
  );
}

function UserTurn({ turn }) {
  return (
    <VStack gap={6} padding={16}>
      <HStack justify="flex-end">
        <VStack padding={14} style={{ background: 'var(--fg)', borderRadius: '18px 18px 4px 18px' }}>
          <Text shrink whiteSpace="pre-wrap" font={`15px ${SANS}`} lineHeight={24} color="var(--bg)">
            {turn.text}
          </Text>
        </VStack>
      </HStack>
      <Escape height={28}>
        <div className="row-actions right">
          <Switcher turn={turn} />
          <button className="ghost" onClick={() => handlers.edit(turn)} title="Edit: branch from here">
            <Pencil size={13} /> Edit
          </button>
        </div>
      </Escape>
    </VStack>
  );
}

function IconCopy({ text, label, Icon = Copy }) {
  const [state, setState] = useState('');
  return (
    <button type="button" className="tc-iconbtn" title={state === 'failed' ? 'Clipboard unavailable' : state === 'copied' ? 'Copied' : label}
      aria-label={label} onClick={async () => {
        try { await navigator.clipboard.writeText(text); setState('copied'); setTimeout(() => setState(''), 1400); }
        catch { setState('failed'); }
      }}>
      {state === 'copied' ? <Check size={13} /> : <Icon size={13} />}
    </button>
  );
}

const KIND_ICON = {
  read: FileText, search: Search, list: FolderOpen, edit: FilePenLine, git: GitBranch, run: SquareTerminal,
  web: Globe, fetch: Download, plan: ListChecks, tool: Wrench,
};
const TOOL_LIMIT = 5;

/** Visual lines from toolBlock's wrap: one element each, never wrapped by CSS. */
function Lines({ lines, diff }) {
  return lines.map((line, i) => (
    <span key={i} className={`tc-ln${diff ? ` tc-dl tc-dl-${{ '+': 'add', '-': 'del', '@': 'hunk', ' ': 'ctx' }[line.diff]}` : ''}`}
      data-hard={line.hard ? '' : undefined}
      style={line.indent ? { paddingLeft: diff ? `calc(14px + ${2 + line.indent}ch)` : `${line.indent}ch` } : undefined}>
      {diff && line.diff !== '@' && !line.cont ? <span className="tc-sign" aria-hidden="true">{line.diff === '-' ? '−' : line.diff === '+' ? '+' : ''}</span> : null}
      {line.spans.length ? line.spans.map((s, j) => {
        const props = spanProps(s.style);
        return props ? <span key={j} {...props}>{s.text}</span> : s.text;
      }) : '\u200b'}
    </span>
  ));
}

/**
 * The expanded block: one dark surface, `$ command` on top (wrapped, folded
 * past a few lines), output below (wrapped, folded past ~16 lines). It is a
 * measured primitive: mugen asks `measure` for its height at the row width,
 * and the render pins the same height from its own width, so the list and the
 * paint agree.
 */
function ToolBlockView({ tool, view, fold, onFold, bodyId }) {
  const model = blockModelFor(view);
  const host = useRef(null);
  const [width, setWidth] = useState(0);
  const [, setFontTick] = useState(0);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el) return undefined;
    const measure = () => setWidth(el.clientWidth);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    let alive = true;
    document.fonts?.ready.then(() => { if (alive) setFontTick(n => n + 1); });
    return () => { alive = false; observer.disconnect(); };
  }, []);
  const layout = blockLayoutFor(model, width || 640, monoCellWidth(), fold);
  const { head, out, corner } = model;
  const folded = out.lines.length > layout.outShown;
  return (
    <div ref={host} className="tc-blockwrap" style={width ? { height: layout.height } : undefined}>
      <div id={bodyId} className={`tc-block tc-${view.status}`} role="region" aria-label={`${view.label.verb} ${view.label.target}`.trim()}>
        <div className="tc-corner">
          <span className="tc-stamp">
            {corner.status ? <span className={`tc-stamp-status tc-${view.status}`}>{corner.status}</span> : null}
            {corner.time ? <span>{corner.time}</span> : null}
          </span>
          <span className="tc-actions">
            {head.copy ? <IconCopy text={head.copy} label={head.kind === 'command' ? 'Copy command' : 'Copy path'} /> : null}
            {out.text ? <IconCopy text={out.text} label="Copy output" Icon={ClipboardList} /> : null}
            <button type="button" className="tc-iconbtn" title="Open details" aria-label="Open details"
              onClick={() => handlers.inspect(tool.message, 'tools')}><ExternalLink size={13} /></button>
          </span>
        </div>
        <pre className={`tc-head tc-head-${head.kind}`} aria-label={head.kind === 'command' ? 'Command' : undefined}>
          <Lines lines={layout.head} />
        </pre>
        {layout.headFolds ? (
          <button type="button" className="tc-fold" aria-expanded={!!fold.head} onClick={() => onFold('head')}>
            {fold.head ? 'Show less' : `Show ${layout.headHidden} more line${layout.headHidden === 1 ? '' : 's'}`}
          </button>
        ) : null}
        {out.lines.length ? <>
          <div className="tc-sep" />
          <div className="tc-outwrap">
            <pre className={`tc-out tc-out-${out.kind}`}><Lines lines={layout.out} diff={out.kind === 'diff'} /></pre>
            {folded && !fold.out ? <div className="tc-fade" aria-hidden="true" /> : null}
          </div>
          {layout.outFolds ? (
            <div className="tc-foot">
              <button type="button" className="tc-fold" aria-expanded={!!fold.out} onClick={() => onFold('out')}>
                {fold.out ? 'Show less' : `Show all ${out.lines.length.toLocaleString()} lines`}
              </button>
              {layout.capped ? (
                <span className="tc-cap">
                  first {layout.outShown} of {out.lines.length.toLocaleString()} lines ·{' '}
                  <button type="button" className="tc-link" onClick={() => handlers.inspect(tool.message, 'tools')}>Details</button>
                </span>
              ) : null}
            </div>
          ) : null}
        </> : null}
      </div>
    </div>
  );
}

const ToolBlock = markPrimitive(ToolBlockView, {
  name: 'ToolBlock',
  measure: (props, ctx) => blockLayoutFor(blockModelFor(props.view), ctx.width, monoCellWidth(), props.fold).height,
});

/** One quiet line: icon, verb-first label, muted metadata. */
function toolRow(tool, view, { expanded, onToggle, bodyId }) {
  const { label, status, action } = view;
  const Icon = status === 'running' ? Loader2 : status === 'failed' ? TriangleAlert : KIND_ICON[action.kind] || Wrench;
  const full = [label.verb, action.paths?.length ? action.paths.join(', ') : label.target, label.detail].filter(Boolean).join(' ');
  const tooltip = full;
  const counts = action.kind === 'edit' && (action.added || action.removed);
  return (
    <Escape key={`row-${tool.id}`} height={ROW_HEIGHT}>
      <button type="button" className={`tc-row tc-${status}${expanded ? ' tc-open' : ''}`} onClick={onToggle}
        aria-expanded={expanded} aria-controls={expanded ? bodyId : undefined} title={tooltip}>
        <Icon size={14} className={`tc-icon${status === 'running' ? ' spin' : ''}`} aria-hidden="true" />
        {/* Shrink order at narrow widths: detail (grows into spare room only),
            then the right-hand metadata (wraps away whole), then the target. */}
        <span className="tc-verb">{label.verb}</span>
        {label.target ? <span className={label.code ? 'tc-target tc-code' : 'tc-target'}>{label.target}</span> : null}
        {view.error ? <span className="tc-error">{view.error}</span> : null}
        <span className="tc-detail">{label.detail}</span>
        <span className="tc-metas">
          {counts ? (
            <span className="tc-delta" aria-label={`${action.added || 0} lines added, ${action.removed || 0} removed`}>
              {action.added ? <span className="tc-plus">+{action.added}</span> : null}
              {action.removed ? <span className="tc-minus">−{action.removed}</span> : null}
            </span>
          ) : null}
          {view.meta ? <span className="tc-meta">{view.meta}</span> : null}
          {status === 'interrupted' ? <span className="tc-meta">interrupted</span> : null}
          {view.slow ? <span className="tc-meta">{view.slow}</span> : null}
        </span>
        {status === 'running' ? <span className="tc-sr">running</span> : status === 'failed' ? <span className="tc-sr">failed</span> : null}
        <ChevronRight size={13} className="tc-chevron" aria-hidden="true" />
      </button>
    </Escape>
  );
}

function moreButton(key, label, Icon, onClick) {
  return (
    <Escape key={key} height={MORE_HEIGHT}>
      <button type="button" className="tc-more" onClick={onClick}>
        <Icon size={13} className="tc-icon" aria-hidden="true" />
        <span>{label}</span>
      </button>
    </Escape>
  );
}

function toolList(turn, views, { toolOpen, setToolOpen, active }) {
  const all = toolOpen.$all === true;
  const hidden = all || views.length <= TOOL_LIMIT + 1 ? 0 : views.length - TOOL_LIMIT;
  // While a turn streams, the newest calls matter: show the tail. Once done,
  // read top-down: show the head.
  const tail = turn.streaming;
  const start = hidden && tail ? hidden : 0;
  const end = hidden && !tail ? TOOL_LIMIT : views.length;
  const out = [];
  if (hidden && tail) {
    const failed = views.slice(0, hidden).filter(v => v.status === 'failed').length;
    out.push(moreButton('more-top', `Show ${hidden} earlier${failed ? ` · ${failed} failed` : ''}`, ChevronUp, () => setToolOpen({ ...toolOpen, $all: true })));
  }
  turn.tools.slice(start, end).forEach((tool, i) => {
    const view = views[start + i];
    const bodyId = `tool-${tool.message}-${tool.id}`.replace(/[^a-zA-Z0-9_-]/g, '-');
    const autoOpen = view.status === 'running' && view.action.kind === 'run';
    const expanded = toolOpen[tool.id] ?? autoOpen;
    out.push(toolRow(tool, view, { expanded, bodyId, onToggle: () => setToolOpen({ ...toolOpen, [tool.id]: !expanded }) }));
    if (expanded) {
      const fold = { head: !!toolOpen[`${tool.id}:head`], out: !!toolOpen[`${tool.id}:out`] };
      out.push(<ToolBlock key={`block-${tool.id}`} tool={tool} view={view} fold={fold} bodyId={bodyId}
        onFold={part => setToolOpen({ ...toolOpen, [`${tool.id}:${part}`]: !fold[part] })} />);
    }
  });
  if (hidden && !tail) {
    const failed = views.slice(TOOL_LIMIT).filter(v => v.status === 'failed').length;
    out.push(moreButton('more', `Show ${hidden} more${failed ? ` · ${failed} failed` : ''}`, ChevronDown, () => setToolOpen({ ...toolOpen, $all: true })));
  }
  if (all && views.length > TOOL_LIMIT + 1) out.push(moreButton('less', 'Show fewer', ChevronUp, () => setToolOpen({ ...toolOpen, $all: false })));
  return out;
}

function AssistantTurn({ turn, open, setOpen, reasoningOpen, setReasoningOpen, toolOpen, setToolOpen }) {
  const toolsRunning = turn.streaming && turn.tools.some(t => t.ended_ms == null);
  const toolsOpen = open ?? (turn.streaming || toolsRunning);
  const views = turn.tools.map(t => presentTool(t, turn.streaming));
  const runningView = toolsRunning ? views.find(v => v.status === 'running') : null;
  const label = runningView ? `${progressiveLabel(runningView.action)}…` : summarizeTools(views);
  return (
    <VStack gap={12} padding={16}>
      <Escape height={22}>
        <div className="provider-line">
          <span className={`chip ${turn.inspected ? 'chip-on' : ''}`}>{turn.provider}</span>
          {turn.switchedFrom ? (
            <span className="seam">
              <GitBranch size={11} /> switched from {turn.switchedFrom}
            </span>
          ) : null}
          {turn.status === 'Failed' ? <span className="status bad">failed</span> : null}
          {turn.status === 'Interrupted' ? <span className="status">interrupted</span> : null}
        </div>
      </Escape>

      {(turn.reasoning || []).map(block => {
        const done = block.ended_ms != null || !turn.streaming;
        const expanded = reasoningOpen[block.id] ?? !done;
        const seconds = block.ended_ms > block.started_ms
          ? Math.ceil((block.ended_ms - block.started_ms) / 1000)
          : null;
        const label = done ? `Thought${seconds ? ` for ${seconds}s` : ''}` : 'Thinking…';
        return (
          <VStack key={`reasoning-${block.id}`}>
            <Disclosure padding={2} aria-expanded={expanded}
              onClick={() => setReasoningOpen({ ...reasoningOpen, [block.id]: !expanded })}
              style={{ ...buttonReset, borderRadius: 6 }}>
              <Text font={`500 12px ${MONO}`} lineHeight={16} color={INK.muted}>{label}</Text>
            </Disclosure>
            <Collapse id={`reasoning-${block.id}`} open={expanded}>
              <VStack style={NO_SHRINK}>
                <VStack height={10} />
                <HStack gap={13} align="stretch">
                  <VStack width={2} style={{ background: INK.hairline, borderRadius: 2 }} />
                  <VStack gap={10}>
                    <Markdown source={block.text} theme={REASONING_MD_THEME} fade={turn.streaming && !done} />
                  </VStack>
                </HStack>
              </VStack>
            </Collapse>
          </VStack>
        );
      })}

      {turn.tools.length > 0 ? (
        <VStack>
          <Disclosure padding={2} aria-expanded={toolsOpen} onClick={() => setOpen(!toolsOpen)} style={{ ...buttonReset, borderRadius: 6 }}>
            <Text font={`500 12px ${MONO}`} lineHeight={16} color={INK.muted}>
              {label}
            </Text>
          </Disclosure>
          <Collapse id="tools" open={toolsOpen}>
            <VStack style={NO_SHRINK} aria-hidden={!toolsOpen} inert={!toolsOpen ? true : undefined}>
              <VStack height={6} />
              <VStack>
                {toolList(turn, views, { toolOpen, setToolOpen, active: toolsOpen })}
              </VStack>
            </VStack>
          </Collapse>
        </VStack>
      ) : null}

      {turn.text ? <Markdown source={turn.text} theme={MD_THEME} fade={turn.streaming} /> : null}

      {turn.pending || (turn.streaming && turn.text) ? (
        <Text font={`600 15px ${SANS}`} lineHeight={26} color={INK.accent} className="caret">
          ▍
        </Text>
      ) : null}

      {turn.error ? (
        <HStack gap={12} align="stretch">
          <VStack width={2} style={{ background: 'var(--destructive)', borderRadius: 2 }} />
          <Text font={`13px ${MONO}`} lineHeight={20} color="var(--destructive)">
            {turn.error}
          </Text>
        </HStack>
      ) : null}

      {!turn.streaming ? (
        <Escape height={28}>
          <div className="row-actions">
            <button className="ghost" onClick={() => handlers.inspect(turn.id, 'events')} title="Raw provider events">
              <ScrollText size={13} /> Events
            </button>
            {turn.tools.length ? (
              <button className="ghost" onClick={() => handlers.inspect(turn.id, 'tools')}>
                <Wrench size={13} /> Tools
              </button>
            ) : null}
            <button className="ghost" onClick={() => navigator.clipboard.writeText(turn.text)} title="Copy">
              <Copy size={13} />
            </button>
          </div>
        </Escape>
      ) : null}
    </VStack>
  );
}
