// The expanded tool-call block: one dark terminal-like surface with the command
// on top, output below. Rows live in a virtualized list whose heights are
// computed before paint, so the block lays its text out itself: wrapLine breaks
// each source line into visual lines at word boundaries (whole monospace cells),
// the DOM renders exactly those lines with no CSS wrapping, and the height is
// the number of visual lines times the line height. The two can't disagree.
import { charWidth, parseAnsi, textWidth } from './ansi.js';
import { clipText, cleanCommand, describeCommand } from './toolPresentation.js';

export const BLOCK = {
  indent: 28,      // lines the block up with the row's label text
  marginTop: 2,
  marginBottom: 8,
  padX: 14,
  padY: 12,
  font: 12.5,
  line: 19,        // px per wrapped row
  corner: 96,      // reserved at the right of the head for duration / actions
  sep: 21,         // 10px + 1px hairline + 10px between head and output
  foldButton: 26,  // 4px + 22px "Show N more lines" under a folded head
  footer: 30,      // 8px + 22px "Show all N lines" / "Show less"
  headFold: 6,
  outFold: 16,
  outCap: 400,
};

const FONT_FAMILY = "'Geist Mono', monospace";
let cellCache = null;
let loading = false;

/**
 * Width of one monospace cell in px at the block's font size: measured once the
 * real font is available (canvas), 0.6em until then. Kicks off the font load so
 * mugen's font watcher re-measures when it lands.
 */
export function monoCellWidth() {
  if (cellCache) return cellCache;
  const fallback = BLOCK.font * 0.6;
  if (typeof document === 'undefined') return fallback;
  const font = `${BLOCK.font}px ${FONT_FAMILY}`;
  try {
    if (document.fonts && !document.fonts.check(font)) {
      if (!loading) { loading = true; document.fonts.load(font).catch(() => {}); }
      return fallback;
    }
    const ctx = document.createElement('canvas').getContext('2d');
    ctx.font = font;
    const w = ctx.measureText('0'.repeat(200)).width / 200;
    if (w > 0) cellCache = w;
    return cellCache || fallback;
  } catch { return fallback; }
}

/** Number of whole cells that fit in `px`. */
export function columns(px, cell) {
  return Math.max(1, Math.floor(px / cell + 1e-3));
}

/* ── Word wrap ─────────────────────────────────────────────────────────── */

// Break after spaces and after these inside long tokens (paths, flags, lists).
const BREAK_AFTER = new Set([' ', '/', '\\', ',', ';', '|', '&', '=', '(', ')', '[', ']', '{', '}', '-', ':', '+', '>', '<', '!', '?']);
// Weaker opportunities (member access, snake_case), used only when a row has
// no strong one, so `sessions.rs` stays whole whenever a `/` or space will do.
const WEAK_BREAK_AFTER = new Set(['.', '_']);
export const MIN_HANG_COLS = 20;

/**
 * Greedy word wrap of one styled line into visual lines of at most `firstCols`
 * cells (first) and `restCols` cells (continuations). Breaks after spaces and
 * the BREAK_AFTER punctuation; a token longer than the line is hard-broken.
 * Spaces at a break are consumed. Continuations hang under the source
 * indentation when that leaves at least MIN_HANG_COLS columns (and deep
 * indentation is capped the same way on the first row). Styles carry
 * across breaks. Returns [{ spans, width, indent }].
 */
export function wrapLine(line, firstCols, restCols = firstCols) {
  if (line.width <= firstCols) return [{ spans: line.spans, width: line.width, indent: 0 }];
  const cells = [];
  line.spans.forEach((s, si) => { for (const ch of s.text) cells.push({ ch, w: charWidth(ch.codePointAt(0)), si }); });
  let lead = 0;
  while (lead < cells.length && cells[lead].ch === ' ') lead++;
  // Deep indentation at a narrow width would leave no room for the first word
  // (forcing a mid-word break), so cap it to leave MIN_HANG_COLS for content.
  const keep = Math.max(0, firstCols - MIN_HANG_COLS);
  if (lead > keep) { cells.splice(0, lead - keep); lead = keep; }
  const indent = lead && restCols - lead >= MIN_HANG_COLS ? lead : 0;
  const out = [];
  let start = 0;
  while (start < cells.length) {
    const first = out.length === 0;
    const cap = Math.max(1, first ? firstCols : restCols - indent);
    let w = 0;
    let i = start;
    let lastBreak = -1;
    let lastWeak = -1;
    let seenText = false;
    while (i < cells.length && w + cells[i].w <= cap) {
      const c = cells[i];
      if (c.ch !== ' ') seenText = true;
      w += c.w;
      i++;
      if (seenText && i < cells.length) {
        if (BREAK_AFTER.has(c.ch)) lastBreak = i;
        else if (WEAK_BREAK_AFTER.has(c.ch) && i - start > 1) lastWeak = i;
      }
    }
    let end;
    if (i >= cells.length) end = cells.length;
    else if (cells[i].ch === ' ' && seenText) end = i;          // break before a space run
    else if (lastBreak > start) end = lastBreak;                 // last word boundary
    else if (lastWeak > start) end = lastWeak;                   // inside an identifier
    else end = Math.max(i, start + 1);                           // over-long token: hard break
    const hard = end < cells.length && end !== lastBreak && end !== lastWeak && cells[end].ch !== ' ';
    let shown = end; // trailing spaces at a break aren't drawn
    while (end < cells.length && shown > start + 1 && cells[shown - 1].ch === ' ') shown--;
    out.push({ ...visual(cells, line.spans, start, shown, first ? 0 : indent), ...(hard ? { hard } : null) });
    start = end;
    while (start < cells.length && cells[start].ch === ' ') start++; // spaces at a break are consumed
  }
  return out;
}

function visual(cells, spans, start, end, indent) {
  const out = [];
  let width = 0;
  for (let k = start; k < end; k++) {
    const c = cells[k];
    width += c.w;
    const last = out.at(-1);
    if (last && last.si === c.si) last.text += c.ch;
    else out.push({ si: c.si, text: c.ch, style: spans[c.si].style });
  }
  return { spans: out.map(({ text, style }) => ({ text, style })), width, indent, cont: start > 0 };
}

/** Wrap a list of source lines; the first visual row may be narrower. */
export function wrapLines(lines, cols, firstCols = cols) {
  const out = [];
  lines.forEach((line, n) => {
    for (const v of wrapLine(line, n === 0 ? firstCols : cols, cols)) out.push(line.diff ? { ...v, diff: line.diff } : v);
  });
  return out;
}

/* ── Command tint: program bright, flags muted, strings coloured ──────────── */

const span = (text, k) => ({ text, style: k ? { k } : undefined });

export function tintCommand(text) {
  const out = [];
  let atStart = true;
  let heredoc = null; // delimiter while inside a heredoc body
  const lines = String(text).split('\n');
  lines.forEach((line, li) => {
    if (li) out.push(span('\n'));
    if (heredoc) {
      out.push(span(line, line.trim() === heredoc ? 'op' : 'body'));
      if (line.trim() === heredoc) { heredoc = null; atStart = true; }
      return;
    }
    const re = /(\s+)|('(?:[^']*)'?|"(?:\\.|[^"\\])*"?)|(&&|\|\||<<-?|>>|[|;&<>()])|([^\s'"|;&<>()]+)/g;
    let m;
    while ((m = re.exec(line))) {
      const [tok, ws, str, op, word] = m;
      if (ws) out.push(span(tok));
      else if (str) { out.push(span(tok, 'str')); atStart = false; }
      else if (op) {
        out.push(span(tok, 'op'));
        if (/^<<-?$/.test(op)) {
          const d = line.slice(re.lastIndex).match(/^\s*['"]?(\w+)['"]?/);
          if (d) heredoc = d[1];
        } else if (op !== '>' && op !== '>>' && op !== '<') atStart = true;
      } else if (word) {
        if (atStart && !/^[A-Za-z_][A-Za-z0-9_]*=/.test(word)) { out.push(span(tok, 'prog')); atStart = false; }
        else out.push(span(tok, /^-/.test(word) ? 'flag' : /^\$/.test(word) ? 'var' : undefined));
      }
    }
    if (!/\\$/.test(line)) atStart = true;
  });
  return splitLines(out);
}

/** Split spans at newlines into measured lines (tabs expanded). */
function splitLines(spans) {
  const lines = [{ spans: [], width: 0 }];
  for (const s of spans) {
    const parts = s.text.split('\n');
    parts.forEach((p, i) => {
      if (i) lines.push({ spans: [], width: 0 });
      if (!p) return;
      const line = lines.at(-1);
      const text = p.replace(/\t/g, '    ');
      line.spans.push({ text, style: s.style });
      line.width += textWidth(text);
    });
  }
  return lines;
}

const muted = text => [{ spans: [span(text, 'muted')], width: textWidth(text) }];

function headLines(view) {
  const action = view.action;
  if (view.command) {
    const described = action.shown != null ? action : describeCommand(view.command);
    const text = described.shown ?? cleanCommand(view.command);
    const lines = tintCommand(text);
    const prefix = described.cwd ? `${described.cwd} › ` : '$ ';
    lines[0] = { spans: [span(prefix, 'prompt'), ...lines[0].spans], width: lines[0].width + textWidth(prefix) };
    return { kind: 'command', lines, copy: Array.isArray(view.command) ? view.command.join(' ') : String(view.command) };
  }
  const paths = action.paths?.length ? action.paths : view.path ? [view.path] : [];
  if (paths.length) {
    const lines = paths.map(p => {
      const cut = p.lastIndexOf('/') + 1;
      const spans = [span(p.slice(0, cut), 'muted'), span(p.slice(cut), 'prog')].filter(s => s.text);
      return { spans, width: textWidth(p) };
    });
    if (action.detail) { lines.at(-1).spans.push(span(`  ${action.detail}`, 'muted')); lines.at(-1).width += textWidth(action.detail) + 2; }
    return { kind: 'path', lines, copy: paths.join('\n') };
  }
  const label = [action.verb, action.target].filter(Boolean).join(' ');
  return { kind: 'name', lines: [{ spans: [span(label, 'prog')], width: textWidth(label) }], copy: '' };
}

function outputLines(view) {
  const action = view.action;
  if (action.kind === 'edit' && action.diff?.length) {
    const lines = [];
    for (const d of action.diff) {
      const parsed = parseAnsi(d.text)[0] || { spans: [], width: 0 };
      lines.push({ ...parsed, diff: d.type });
    }
    return { kind: 'diff', lines, text: action.diff.map(d => `${d.type === '@' ? '' : d.type}${d.text}`).join('\n') };
  }
  const lines = [];
  const generic = ['tool', 'web', 'fetch', 'plan'].includes(action.kind) || (action.kind === 'edit' && !view.command);
  if (generic && Object.keys(view.input || {}).length) {
    lines.push(...parseAnsi(JSON.stringify(view.input, null, 2)).map(l => ({ ...l, spans: l.spans.map(s => ({ ...s, style: { k: 'muted' } })) })));
  }
  let clipped = false;
  for (const s of view.terminalSections) {
    const c = clipText(s.text);
    clipped ||= c.clipped;
    if (lines.length) lines.push({ spans: [], width: 0 });
    lines.push(...parseAnsi(c.text, s.error ? { err: true } : undefined));
  }
  // Providers that merge stderr into one stream: tint the line the row cites.
  if (view.status === 'failed' && view.error && !view.terminalSections.some(s => s.error)) {
    for (const l of lines) {
      if (l.spans.map(sp => sp.text).join('').trim() === view.error) l.spans = l.spans.map(sp => ({ ...sp, style: { ...sp.style, err: true } }));
    }
  }
  if (clipped) lines.push(...muted('… output clipped here; the full output is in Details.'));
  if (!view.terminalSections.length) {
    lines.push(...muted(view.status === 'running' ? 'Waiting for output…'
      : view.status === 'interrupted' ? 'Interrupted before a result was recorded.' : 'No output.'));
  }
  return { kind: 'ansi', lines, text: view.sections.map(s => s.text).join('\n') };
}

function corner(view) {
  const ms = view.durationMs;
  const time = ms == null ? '' : ms < 1000 ? `${ms}ms` : view.duration;
  let status = '';
  if (view.status === 'failed') {
    const code = view.sections.map(s => s.text.match(/^Exit code (\d+)/im)?.[1]).find(Boolean);
    status = code ? `exit ${code}` : 'failed';
  } else if (view.status === 'running') status = 'running…';
  else if (view.status === 'interrupted') status = 'interrupted';
  return { time, status };
}

/** Everything the block shows, independent of width. */
export function blockModel(view) {
  return { head: headLines(view), out: outputLines(view), corner: corner(view), status: view.status };
}

const models = new WeakMap();
/** blockModel, cached per presented view (views are cached per tool row). */
export function blockModelFor(view) {
  let m = models.get(view);
  if (!m) { m = blockModel(view); models.set(view, m); }
  return m;
}

/**
 * Lay the block out at a row width (px) and cell width (px). `fold` is
 * { head: bool, out: bool } — true when the user expanded that part.
 */
export function blockLayout(model, width, cell, fold = {}) {
  const inner = Math.max(40, width - BLOCK.indent - 2 * BLOCK.padX);
  const headCols = columns(Math.max(cell * 8, inner - BLOCK.corner), cell);
  const outCols = columns(inner, cell);
  const diffCols = Math.max(1, outCols - 2);

  const headTotal = model.head.lines.length;
  const headFolds = headTotal > BLOCK.headFold + 1;
  const headShown = headFolds && !fold.head ? BLOCK.headFold : headTotal;
  // The corner floats beside the first visual row only; later rows use the full width.
  const head = wrapLines(model.head.lines.slice(0, headShown), outCols, headCols);
  const headRows = head.length;

  const outTotal = model.out.lines.length;
  const outFolds = outTotal > BLOCK.outFold + 2;
  const outShown = !outFolds ? outTotal : fold.out ? Math.min(outTotal, BLOCK.outCap) : BLOCK.outFold;
  const out = wrapLines(model.out.lines.slice(0, outShown), model.out.kind === 'diff' ? diffCols : outCols);
  const outRows = out.length;

  const height = BLOCK.marginTop + BLOCK.padY
    + headRows * BLOCK.line + (headFolds ? BLOCK.foldButton : 0)
    + (outTotal ? BLOCK.sep + outRows * BLOCK.line + (outFolds ? BLOCK.footer : 0) : 0)
    + BLOCK.padY + BLOCK.marginBottom;
  return {
    height, headCols, outCols, headShown, headHidden: headTotal - headShown, headFolds,
    outShown, outHidden: outTotal - outShown, outFolds, capped: fold.out && outTotal > BLOCK.outCap,
    headRows, outRows, head, out,
  };
}

const layouts = new WeakMap();
/** blockLayout, memoized per model for the last few (width, cell, fold) keys. */
export function blockLayoutFor(model, width, cell, fold = {}) {
  const key = `${width}|${cell}|${fold.head ? 1 : 0}${fold.out ? 1 : 0}`;
  let cache = layouts.get(model);
  if (!cache) { cache = new Map(); layouts.set(model, cache); }
  let l = cache.get(key);
  if (!l) {
    l = blockLayout(model, width, cell, fold);
    cache.set(key, l);
    if (cache.size > 6) cache.delete(cache.keys().next().value);
  }
  return l;
}
