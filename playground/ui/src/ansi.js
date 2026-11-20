// A small ANSI renderer for stored command output: SGR styling (16 colours,
// bright, 256-colour and truecolor; bold/dim/italic/underline/inverse) becomes
// spans; carriage-return progress keeps its last frame; every other escape
// (cursor moves, erases, OSC hyperlinks/titles, clipboard) is dropped. Output
// is always text, never HTML.

const PALETTE_256 = (() => {
  const out = [];
  const base = ['#000000', '#cd3131', '#0dbc79', '#e5e510', '#2472c8', '#bc3fbc', '#11a8cd', '#e5e5e5',
    '#666666', '#f14c4c', '#23d18b', '#f5f543', '#3b8eea', '#d670d6', '#29b8db', '#ffffff'];
  out.push(...base);
  const steps = [0, 95, 135, 175, 215, 255];
  for (let r = 0; r < 6; r++) for (let g = 0; g < 6; g++) for (let b = 0; b < 6; b++) {
    out.push(`rgb(${steps[r]},${steps[g]},${steps[b]})`);
  }
  for (let i = 0; i < 24; i++) { const v = 8 + i * 10; out.push(`rgb(${v},${v},${v})`); }
  return out;
})();

const EMPTY = Object.freeze({});

function applySgr(style, params) {
  const s = { ...style };
  const p = params.length ? params : [0];
  for (let i = 0; i < p.length; i++) {
    const n = p[i];
    if (n === 0 || Number.isNaN(n)) { for (const k of Object.keys(s)) delete s[k]; }
    else if (n === 1) s.bold = true;
    else if (n === 2) s.dim = true;
    else if (n === 3) s.italic = true;
    else if (n === 4) s.underline = true;
    else if (n === 7) s.inverse = true;
    else if (n === 9) s.strike = true;
    else if (n === 21 || n === 22) { delete s.bold; delete s.dim; }
    else if (n === 23) delete s.italic;
    else if (n === 24) delete s.underline;
    else if (n === 27) delete s.inverse;
    else if (n === 29) delete s.strike;
    else if (n >= 30 && n <= 37) s.fg = n - 30;
    else if (n >= 90 && n <= 97) s.fg = n - 90 + 8;
    else if (n === 39) delete s.fg;
    else if (n >= 40 && n <= 47) s.bg = n - 40;
    else if (n >= 100 && n <= 107) s.bg = n - 100 + 8;
    else if (n === 49) delete s.bg;
    else if (n === 38 || n === 48) {
      const key = n === 38 ? 'fg' : 'bg';
      if (p[i + 1] === 5 && p[i + 2] != null) { const c = p[i + 2]; s[key] = c < 16 ? c : PALETTE_256[c] ?? undefined; i += 2; }
      else if (p[i + 1] === 2 && p[i + 4] != null) { s[key] = `rgb(${p[i + 2]},${p[i + 3]},${p[i + 4]})`; i += 4; }
    }
  }
  return Object.keys(s).length ? s : EMPTY;
}

const TAB = 4;

/** East Asian wide / emoji code points take two cells. Combining marks take none. */
export function charWidth(cp) {
  if (cp === 0x200b || cp === 0x200d || (cp >= 0x300 && cp <= 0x36f) || (cp >= 0xfe00 && cp <= 0xfe0f)) return 0;
  if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) || (cp >= 0xac00 && cp <= 0xd7a3)
    || (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60)
    || (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff) || (cp >= 0x20000 && cp <= 0x3fffd)) return 2;
  return 1;
}

export function textWidth(text) {
  let w = 0;
  for (const ch of text) w += charWidth(ch.codePointAt(0));
  return w;
}

/**
 * Parse terminal output into lines of styled spans:
 * [{ spans: [{ text, style }], width }]. Tabs are expanded to spaces so the
 * rendered text and the measured width agree.
 */
export function parseAnsi(input, baseStyle = EMPTY) {
  const text = String(input ?? '').replace(/\r\n/g, '\n');
  const lines = [];
  let style = baseStyle;
  let spans = [];
  let col = 0;
  let buf = '';
  const flush = () => {
    if (!buf) return;
    const last = spans.at(-1);
    if (last && last.style === style) last.text += buf; else spans.push({ text: buf, style });
    buf = '';
  };
  const endLine = () => { flush(); lines.push({ spans, width: col }); spans = []; col = 0; };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '\x1b') {
      const next = text[i + 1];
      if (next === '[') {
        let j = i + 2;
        while (j < text.length && !/[@-~]/.test(text[j])) j++;
        if (text[j] === 'm' && !/[<=>?]/.test(text[i + 2] ?? '')) {
          flush();
          const raw = text.slice(i + 2, j);
          style = applySgr(style, raw === '' ? [] : raw.split(/[;:]/).map(x => (x === '' ? 0 : Number(x))));
          if (style === EMPTY && baseStyle !== EMPTY) style = baseStyle;
        }
        i = j;
      } else if (next === ']' || next === 'P' || next === '_' || next === '^') {
        // OSC/DCS/APC/PM: skip to BEL or ST.
        let j = i + 2;
        while (j < text.length && text[j] !== '\x07' && !(text[j] === '\x1b' && text[j + 1] === '\\')) j++;
        i = text[j] === '\x07' ? j : j + 1;
      } else {
        i += 1; // two-byte escape (ESC 7, ESC =, …)
      }
      continue;
    }
    if (c === '\n') { endLine(); continue; }
    if (c === '\r') { buf = ''; spans = []; col = 0; continue; } // progress frame: keep the latest
    if (c === '\t') { const n = TAB - (col % TAB); buf += ' '.repeat(n); col += n; continue; }
    const code = c.charCodeAt(0);
    if (code < 0x20 || code === 0x7f) continue;
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const pair = c + text[i + 1];
      buf += pair;
      col += charWidth(pair.codePointAt(0));
      i++;
      continue;
    }
    buf += c;
    col += charWidth(code);
  }
  endLine();
  // A trailing newline ends the last line; it doesn't start an empty one.
  while (lines.length > 1 && lines.at(-1).width === 0 && !lines.at(-1).spans.length) lines.pop();
  return lines;
}

/** Inline style + class for a span's SGR state (colours 0–15 come from CSS). */
export function spanProps(style) {
  if (!style || style === EMPTY) return null;
  let { fg, bg } = style;
  if (style.inverse) [fg, bg] = [bg ?? 'inv-fg', fg ?? 'inv-bg'];
  const cls = [];
  const css = {};
  if (typeof fg === 'number') cls.push(`tc-fg${fg}`); else if (fg === 'inv-fg') cls.push('tc-fg-inv'); else if (fg) css.color = fg;
  if (typeof bg === 'number') cls.push(`tc-bg${bg}`); else if (bg === 'inv-bg') cls.push('tc-bg-inv'); else if (bg) css.background = bg;
  if (style.bold) cls.push('tc-b');
  if (style.dim) cls.push('tc-dim');
  if (style.italic) cls.push('tc-i');
  if (style.underline) cls.push('tc-u');
  if (style.strike) cls.push('tc-s');
  if (style.err) cls.push('tc-err');
  if (style.k) cls.push(`tc-k-${style.k}`);
  return { className: cls.join(' ') || undefined, style: Object.keys(css).length ? css : undefined };
}
