import test from 'node:test';
import assert from 'node:assert/strict';
import { parseAnsi, spanProps, textWidth } from './ansi.js';

const plain = lines => lines.map(l => l.spans.map(s => s.text).join(''));

test('SGR colours, bright, bold and reset become spans', () => {
  const [line] = parseAnsi('\x1b[32mPASS\x1b[0m \x1b[1;91m2 failed\x1b[0m');
  assert.deepEqual(line.spans.map(s => s.text), ['PASS', ' ', '2 failed']);
  assert.equal(line.spans[0].style.fg, 2);
  assert.equal(spanProps(line.spans[1].style), null);
  assert.deepEqual(line.spans[2].style, { bold: true, fg: 9 });
  assert.equal(spanProps(line.spans[2].style).className, 'tc-fg9 tc-b');
  assert.equal(line.width, 13);
});

test('256-colour and truecolor arrive as inline colours', () => {
  const [a] = parseAnsi('\x1b[38;5;196mred\x1b[0m\x1b[48;2;10;20;30mbg');
  assert.equal(a.spans[0].style.fg, 'rgb(255,0,0)');
  assert.equal(spanProps(a.spans[1].style).style.background, 'rgb(10,20,30)');
  const [b] = parseAnsi('\x1b[38;5;3mlow');
  assert.equal(b.spans[0].style.fg, 3);
});

test('carriage-return progress keeps the latest frame; other escapes vanish', () => {
  assert.deepEqual(plain(parseAnsi('Building 10%\r\x1b[2KBuilding 100%\nDone\n')), ['Building 100%', 'Done']);
  assert.deepEqual(plain(parseAnsi('\x1b]8;;https://x.y\x1b\\link\x1b]8;;\x1b\\ \x1b[1A\x1b[?25lok\x07')), ['link ok']);
  assert.deepEqual(plain(parseAnsi('<script>alert(1)</script>')), ['<script>alert(1)</script>']);
});

test('tabs expand to the next 4-cell stop; wide characters take two cells', () => {
  const [l] = parseAnsi('a\tb\tc');
  assert.equal(plain([l])[0], 'a   b   c');
  assert.equal(l.width, 9);
  assert.equal(textWidth('界✓'), 3);
  assert.equal(textWidth('é'), 1);
});

test('stderr base style survives inner resets', () => {
  const [l] = parseAnsi('err \x1b[1mbold\x1b[0m tail', { err: true });
  assert.ok(l.spans.every(s => s.style.err));
  assert.ok(spanProps(l.spans[0].style).className.includes('tc-err'));
});
