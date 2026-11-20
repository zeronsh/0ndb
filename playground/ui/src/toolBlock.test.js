import test from 'node:test';
import assert from 'node:assert/strict';
import { presentTool } from './toolPresentation.js';
import { parseAnsi } from './ansi.js';
import { BLOCK, blockLayout, blockModel, columns, MIN_HANG_COLS, monoCellWidth, tintCommand, wrapLine, wrapLines } from './toolBlock.js';

const tool = o => ({ name: 'Bash', input: '{}', started_ms: 0, ended_ms: 12, ...o });
const CELL = 7.5; // 12.5px Geist Mono ≈ 0.6em
const words = line => line.spans.map(s => s.text).join('');

const vis = rows => rows.map(r => ' '.repeat(r.indent) + r.spans.map(x => x.text).join(''));
const src = text => parseAnsi(text)[0];

test('cell columns: whole cells, exact fits are not off by one', () => {
  assert.equal(monoCellWidth(), BLOCK.font * 0.6); // no DOM: 0.6em fallback
  assert.equal(columns(268, CELL), 35);
  assert.equal(columns(270, 7.5), 36);
});

test('wrap breaks at word boundaries and consumes the spaces at a break', () => {
  const rows = wrapLine(src('Markdown makes it easy to turn plain text into clear documents'), 20);
  assert.deepEqual(vis(rows), ['Markdown makes it', 'easy to turn plain', 'text into clear', 'documents']);
  assert.ok(rows.every(r => r.width <= 20));
  // A line that fits is returned as-is, and an empty line is one visual row.
  assert.equal(wrapLine(src('short'), 20).length, 1);
  assert.deepEqual(vis(wrapLine({ spans: [], width: 0 }, 20)), ['']);
});

test('long tokens break after path and list punctuation, hard-break only when unbreakable', () => {
  assert.deepEqual(vis(wrapLine(src('crates/ondb-agents/src/sessions.rs'), 16)), ['crates/ondb-', 'agents/src/', 'sessions.rs']);
  assert.deepEqual(vis(wrapLine(src("rg -n 'a|b|c|d' x"), 10)), ["rg -n 'a|", "b|c|d' x"]);
  assert.deepEqual(vis(wrapLine(src('x'.repeat(25)), 10)), ['xxxxxxxxxx', 'xxxxxxxxxx', 'xxxxx']);
  // "sessions.rs" is never split at the dot.
  assert.ok(!vis(wrapLine(src('cat crates/ondb-agents/src/sessions.rs'), 30)).some(l => /sessi$|^ons/.test(l)));
});

test('continuations hang under the source indentation when room allows', () => {
  const code = '        let before = doc.export_snapshot().unwrap(); // a trailing comment that wraps';
  const wide = wrapLine(src(code), 50);
  assert.equal(wide[0].indent, 0);
  assert.ok(wide.slice(1).every(r => r.indent === 8));
  assert.ok(wide.every(r => r.width + r.indent <= 50));
  // Deep indentation is capped so the first word still fits (no mid-word break).
  assert.deepEqual(vis(wrapLine(src(' '.repeat(32) + '*resolved = true;'), 35)), [' '.repeat(15) + '*resolved = true;']);
  assert.deepEqual(vis(wrapLine(src(' '.repeat(16) + 'chat.last_message_at = None;'), 35)),
    [' '.repeat(15) + 'chat.last_message_at', ' '.repeat(15) + '= None;']);
  // At a narrow width the hang shrinks with the capped indentation.
  const narrow = wrapLine(src(code), 8 + MIN_HANG_COLS - 1);
  assert.ok(narrow.slice(1).every(r => r.indent === 7));
  // Too narrow to hang at all (< MIN_HANG_COLS of room): continuations start at column 0.
  assert.ok(wrapLine(src(code), MIN_HANG_COLS - 2).slice(1).every(r => r.indent === 0));
  // Identifiers split after '.'/'_' only when nothing stronger is available.
  assert.deepEqual(vis(wrapLine(src('x = source_chat_id.clone();'), 20)), ['x =', 'source_chat_id.', 'clone();']);
  assert.deepEqual(vis(wrapLine(src('cat src/sessions.rs'), 16)), ['cat src/', 'sessions.rs']);
});

test('ANSI styles survive a break; first row can be narrower than the rest', () => {
  const [line] = parseAnsi('\x1b[31mred words here\x1b[0m and plain words');
  const rows = wrapLine(line, 10, 20);
  assert.deepEqual(vis(rows), ['red words', 'here and plain words']);
  assert.equal(rows[0].spans[0].style.fg, 1);
  assert.equal(rows[1].spans[0].text, 'here');
  assert.equal(rows[1].spans[0].style.fg, 1);
  assert.equal(rows[1].spans[1].style, line.spans[1].style);
  // wrapLines narrows only the very first visual row.
  assert.deepEqual(vis(wrapLines([src('aaaa bbbb cccc'), src('dddd eeee')], 10, 5)), ['aaaa', 'bbbb cccc', 'dddd eeee']);
});

test('block height = chrome + wrapped head rows + separator + wrapped output rows', () => {
  const view = presentTool(tool({ input: JSON.stringify({ command: '/bin/zsh -lc "rtk proxy cat a.txt"' }), stdout: 'x'.repeat(100) + '\nshort\n' }));
  const model = blockModel(view);
  assert.equal(words(model.head.lines[0]), '$ cat a.txt');
  const width = 28 + 28 + 75 * CELL; // 75 output columns
  const l = blockLayout(model, width, CELL);
  assert.equal(l.outCols, 75);
  assert.equal(l.outRows, 2 + 1);
  assert.equal(l.headRows, 1);
  const chrome = BLOCK.marginTop + 2 * BLOCK.padY + BLOCK.marginBottom;
  assert.equal(l.height, chrome + BLOCK.line + BLOCK.sep + 3 * BLOCK.line);
  // Narrower → more rows → taller; heights are a pure function of width.
  assert.ok(blockLayout(model, 28 + 28 + 30 * CELL, CELL).height > l.height);
});

test('the corner only shortens the first head row', () => {
  const view = presentTool(tool({ input: JSON.stringify({ command: `echo ${'a'.repeat(200)}` }), stdout: 'ok' }));
  const model = blockModel(view);
  const width = 28 + 28 + 60 * CELL; // 60 cols; corner takes 96px ≈ 12.8 cells
  const l = blockLayout(model, width, CELL);
  assert.equal(l.headCols, 47);
  // "$ echo " fits beside the corner; the 200-cell token then fills full rows.
  assert.deepEqual(l.head.map(r => r.width), [6, 60, 60, 60, 20]);
  assert.equal(l.headRows, 5);
  assert.equal(l.height, BLOCK.marginTop + 2 * BLOCK.padY + BLOCK.marginBottom + 5 * BLOCK.line + BLOCK.sep + BLOCK.line);
});

test('long output folds at 16 lines with a footer; show-all caps at 400', () => {
  const out = Array.from({ length: 1000 }, (_, i) => `line ${i}`).join('\n');
  const model = blockModel(presentTool(tool({ input: JSON.stringify({ command: 'seq 1000' }), stdout: out })));
  const folded = blockLayout(model, 800, CELL);
  assert.equal(folded.outShown, 16);
  assert.equal(folded.outFolds, true);
  assert.equal(folded.outHidden, 984);
  const open = blockLayout(model, 800, CELL, { out: true });
  assert.equal(open.outShown, 400);
  assert.equal(open.capped, true);
  assert.equal(open.height - folded.height, (400 - 16) * BLOCK.line);
  // 17 lines doesn't fold into "Show 1 more".
  const few = blockModel(presentTool(tool({ input: '{"command":"x"}', stdout: Array(18).fill('a').join('\n') })));
  assert.equal(blockLayout(few, 800, CELL).outFolds, false);
});

test('heredoc commands fold after six lines and toggle back', () => {
  const cmd = `python3 - <<'PY'\n${Array.from({ length: 10 }, (_, i) => `print(${i})`).join('\n')}\nPY`;
  const model = blockModel(presentTool(tool({ input: JSON.stringify({ command: cmd }), stdout: 'ok' })));
  assert.equal(model.head.lines.length, 12);
  const folded = blockLayout(model, 800, CELL);
  assert.equal(folded.headShown, 6);
  assert.equal(folded.headHidden, 6);
  const open = blockLayout(model, 800, CELL, { head: true });
  assert.equal(open.height - folded.height, 6 * BLOCK.line);
});

test('cd prefix is shown as context; commands are tinted', () => {
  const model = blockModel(presentTool(tool({ input: JSON.stringify({ command: "cd crates/ondb && rg -n 'fn main' src" }), stdout: 'x' })));
  assert.equal(words(model.head.lines[0]), "crates/ondb › rg -n 'fn main' src");
  const kinds = Object.fromEntries(tintCommand("rg -n 'fn main' src | head -5")[0].spans.filter(s => s.style).map(s => [s.text, s.style.k]));
  assert.deepEqual(kinds, { rg: 'prog', '-n': 'flag', "'fn main'": 'str', '|': 'op', head: 'prog', '-5': 'flag' });
});

test('failures: stderr tinted, merged-stream error line tinted, status in the corner', () => {
  const merged = blockModel(presentTool(tool({ input: '{"command":"cat a b"}', is_error: 1, output: 'Exit code 1\nhello\ncat: b: No such file or directory' })));
  assert.deepEqual(merged.corner, { time: '12ms', status: 'exit 1' });
  const errLine = merged.out.lines.find(l => words(l).startsWith('cat: b'));
  assert.ok(errLine.spans.every(s => s.style.err));
  const split = blockModel(presentTool(tool({ input: '{"command":"x"}', is_error: 1, stdout: 'ok', stderr: 'boom' })));
  assert.ok(split.out.lines.at(-1).spans[0].style.err);
  assert.equal(split.corner.status, 'failed');
});

test('edits render as a diff in the same block; reads of native tools show the path', () => {
  const edit = blockModel(presentTool(tool({ name: 'Edit', input: JSON.stringify({ file_path: '/r/src/a.ts', old_string: 'a\nb', new_string: 'a\nB' }) })));
  assert.equal(edit.out.kind, 'diff');
  assert.deepEqual(edit.out.lines.map(l => l.diff), [' ', '-', '+']);
  assert.equal(edit.head.kind, 'path');
  assert.equal(words(edit.head.lines[0]), '/r/src/a.ts');
  // Diff rows wrap two cells narrower (the sign gutter).
  const long = blockModel(presentTool(tool({ name: 'Write', input: JSON.stringify({ file_path: 'x.md', content: 'y'.repeat(74) }) })));
  assert.equal(blockLayout(long, 28 + 28 + 75 * CELL, CELL).outRows, 2);
});
