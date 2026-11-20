// Presentation of normalized tool calls; provider wire formats stay in the drivers.
export function parseInput(input) {
  if (input && typeof input === 'object') return input;
  try { return JSON.parse(input || '{}') || {}; } catch { return { input }; }
}

export function terminalText(value) {
  // Render text, never terminal escapes or HTML. Keep only the latest frame of
  // carriage-return progress lines, and remove OSC (including hyperlinks).
  return String(value ?? '')
    .replace(/\x1b\][\s\S]*?(?:\x07|\x1b\\)/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\r\n/g, '\n')
    .split('\n').map(line => line.split('\r').at(-1)).join('\n')
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');
}

function outputText(value) {
  if (value == null || value === '') return '';
  let text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  try {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed) && parsed.every(b => b.type === 'text')) {
      text = parsed.map(b => b.text || '').join('\n');
    } else if (parsed && typeof parsed === 'object') {
      text = JSON.stringify(parsed, null, 2);
    }
  } catch { /* Ordinary CLI output. */ }
  return terminalText(text);
}

const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'fish', 'ksh']);
const basename = p => String(p).replace(/\/+$/, '').split('/').at(-1) || String(p);

export function displayCommand(command) {
  if (Array.isArray(command)) {
    const argv = command.map(String);
    // ["/bin/zsh", "-lc", "npm test"] is a transport wrapper, not the command.
    if (argv.length === 3 && SHELLS.has(basename(argv[0])) && /^-[a-z]*c[a-z]*$/.test(argv[1])) return argv[2];
    return argv.map(a => (/^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)).join(' ');
  }
  const text = String(command || '');
  // Hide a shell's transport wrapper in the summary only; the expanded card
  // and Copy command preserve the exact command received from the harness.
  const match = text.match(/^(?:\/\S*\/)?(?:zsh|bash|sh)\s+-[a-z]*c\s+(["'])([\s\S]*)\1$/);
  if (!match) return text;
  if (match[1] === '"') {
    try { return JSON.parse(`"${match[2]}"`); } catch { /* Shell quoting differs from JSON. */ }
  }
  return match[2];
}

export function duration(tool) {
  if (tool.ended_ms == null || tool.started_ms == null) return '';
  const ms = Math.max(0, tool.ended_ms - tool.started_ms);
  if (ms < 1000) return `${ms} ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(ms < 10000 ? 1 : 0)}s`;
  return `${Math.floor(ms / 60000)}m ${Math.round(ms % 60000 / 1000)}s`;
}

/* ── Shell parsing ──────────────────────────────────────────────────────────
   A small POSIX-ish tokenizer: enough to recognise what a command *does*
   (quotes, escapes, $(…), chains, pipes, redirects, heredocs). It is only used
   to label a row; the exact command is always shown verbatim when expanded. */

export function parseShell(src) {
  const text = String(src ?? '');
  const commands = [];          // [{ pipeline: [segment], op, start, end }]
  let pipeline = [];
  let seg = null;
  let word = null;              // string being built, or null between words
  let pendingRedirect = null;
  const heredocs = [];
  let cmdStart = 0;

  const newSeg = () => ({ words: [], redirects: [], heredoc: null });
  const ensureSeg = () => (seg ??= newSeg());
  const endWord = () => {
    if (word == null) return;
    if (pendingRedirect) {
      ensureSeg().redirects.push({ op: pendingRedirect, target: word });
      if (pendingRedirect.startsWith('<<') && pendingRedirect !== '<<<') {
        heredocs.push({ delim: word, strip: pendingRedirect === '<<-', seg });
      }
      pendingRedirect = null;
    } else ensureSeg().words.push(word);
    word = null;
  };
  const endSeg = () => {
    endWord();
    if (seg && (seg.words.length || seg.redirects.length)) pipeline.push(seg);
    seg = null;
  };
  const endCommand = (op, at) => {
    endSeg();
    if (pipeline.length) commands.push({ pipeline, op, start: cmdStart, end: at });
    pipeline = [];
    cmdStart = at + (op ? op.length : 0);
  };

  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '\n') {
      endCommand('\n', i);
      i++;
      // Swallow heredoc bodies that started on this line.
      while (heredocs.length) {
        const doc = heredocs.shift();
        const body = [];
        while (i < text.length) {
          const nl = text.indexOf('\n', i);
          const line = text.slice(i, nl < 0 ? text.length : nl);
          i = nl < 0 ? text.length : nl + 1;
          if ((doc.strip ? line.replace(/^\t+/, '') : line) === doc.delim) break;
          body.push(line);
        }
        if (doc.seg) doc.seg.heredoc = body.join('\n');
        const last = commands.at(-1);
        if (last) last.end = i;
      }
      cmdStart = i;
      continue;
    }
    if (c === ' ' || c === '\t') { endWord(); i++; continue; }
    if (c === '\\') {
      if (text[i + 1] === '\n') { i += 2; continue; }
      word = (word ?? '') + (text[i + 1] ?? '');
      i += 2;
      continue;
    }
    if (c === "'") {
      const close = text.indexOf("'", i + 1);
      const end = close < 0 ? text.length : close;
      word = (word ?? '') + text.slice(i + 1, end);
      i = end + 1;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      let out = '';
      while (j < text.length && text[j] !== '"') {
        if (text[j] === '\\' && '"\\$`\n'.includes(text[j + 1])) { out += text[j + 1]; j += 2; } else out += text[j++];
      }
      word = (word ?? '') + out;
      i = j + 1;
      continue;
    }
    if (c === '$' && text[i + 1] === '(') {
      let depth = 0;
      let j = i + 1;
      for (; j < text.length; j++) {
        if (text[j] === '(') depth++;
        else if (text[j] === ')' && --depth === 0) break;
      }
      word = (word ?? '') + text.slice(i, j + 1);
      i = j + 1;
      continue;
    }
    if (c === '`') {
      const close = text.indexOf('`', i + 1);
      const end = close < 0 ? text.length : close;
      word = (word ?? '') + text.slice(i, end + 1);
      i = end + 1;
      continue;
    }
    if (c === '#' && word == null) {
      const nl = text.indexOf('\n', i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    const two = text.slice(i, i + 2);
    if (two === '&&' || two === '||') { endCommand(two, i); i += 2; continue; }
    if (c === ';') { endCommand(';', i); i++; continue; }
    if (c === '|') { endSeg(); i++; continue; }
    if (c === '&' && text[i + 1] === '>') { endWord(); pendingRedirect = '>'; i += text[i + 2] === '>' ? 3 : 2; continue; }
    if (c === '&') { endCommand('&', i); i++; continue; }
    if (c === '>' || c === '<') {
      // A bare fd number before the operator belongs to the redirect (2>&1).
      if (word != null && /^\d+$/.test(word)) word = null; else endWord();
      let op = c;
      let j = i + 1;
      if (c === '<' && text[j] === '<') { op = '<<'; j++; if (text[j] === '<') { op = '<<<'; j++; } else if (text[j] === '-') { op = '<<-'; j++; } }
      else if (c === '>' && text[j] === '>') { op = '>>'; j++; }
      if (text[j] === '&') { // >&2, 2>&1: duplicate a descriptor, no file.
        j++;
        while (/[\d-]/.test(text[j] ?? '')) j++;
        i = j;
        continue;
      }
      ensureSeg();
      pendingRedirect = op;
      i = j;
      continue;
    }
    word = (word ?? '') + c;
    i++;
  }
  endCommand(null, text.length);
  return commands;
}

const ENV_ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;
const PREFIXES = new Set(['env', 'time', 'nice', 'nohup', 'sudo', 'exec', 'noglob', 'builtin']);
const RTK_META = new Set(['gain', 'discover', 'init', 'config', 'help', '--version', '-V', '--help']);

// Strip launch wrappers from an argv: env assignments, time/sudo/etc, and the
// rtk token-saving proxy (`rtk proxy cmd`, `rtk cmd`).
function stripPrefixes(words) {
  let w = words.slice();
  for (let guard = 0; guard < 8 && w.length; guard++) {
    if (ENV_ASSIGN.test(w[0])) { w.shift(); continue; }
    if (PREFIXES.has(w[0]) && w.length > 1) { w.shift(); while (w[0]?.startsWith('-') || ENV_ASSIGN.test(w[0] ?? '')) w.shift(); continue; }
    if (basename(w[0]) === 'rtk' && w.length > 1 && !RTK_META.has(w[1])) {
      w = w[1] === 'proxy' ? w.slice(2) : w.slice(1);
      if (w[0] === 'read') w[0] = 'cat';
      continue;
    }
    break;
  }
  return w;
}

const isShellC = w => w.length >= 3 && SHELLS.has(basename(w[0])) && /^-[a-z]*c[a-z]*$/.test(w[1]);

// Peel `/bin/zsh -lc '…'`, `rtk proxy …`, `bash -c "…"` (in any nesting) off a
// command until what's left is the command the agent meant to run.
export function unwrapCommand(command) {
  let text = Array.isArray(command) ? displayCommand(command) : String(command ?? '');
  for (let guard = 0; guard < 6; guard++) {
    const parsed = parseShell(text.trim());
    if (parsed.length !== 1 || parsed[0].pipeline.length !== 1) break;
    const words = stripPrefixes(parsed[0].pipeline[0].words);
    if (!isShellC(words)) break;
    text = words[2];
  }
  return text.trim();
}

/** The command line as a person would read it: wrappers and rtk removed. */
export function cleanCommand(command) {
  return unwrapCommand(command)
    .replace(/(^|[|;&(\n]\s*)rtk\s+(?:proxy\s+|(?!(?:gain|discover|init|config|help)\b|-))/g, '$1');
}

function firstLine(text, max = 160) {
  const lines = String(text).split('\n');
  let line = lines[0];
  if (line.length > max) line = `${line.slice(0, max - 1)}…`;
  else if (lines.length > 1) line += ' …';
  return line;
}

const FILTERS = new Set(['head', 'tail', 'sort', 'uniq', 'wc', 'grep', 'rg', 'cut', 'awk', 'sed', 'tr', 'jq', 'column', 'less', 'more', 'cat', 'nl', 'fold', 'tee']);
const NOISE = new Set(['echo', 'printf', 'pwd', 'true', ':', 'clear']);

function flagValue(args, names) {
  for (let i = 0; i < args.length; i++) {
    for (const n of names) {
      if (args[i] === n) return args[i + 1];
      if (n.startsWith('--') && args[i].startsWith(`${n}=`)) return args[i].slice(n.length + 1);
      if (!n.startsWith('--') && args[i].startsWith(n) && args[i].length > n.length && /^\d/.test(args[i].slice(n.length))) return args[i].slice(n.length);
    }
  }
  return undefined;
}

// Split argv into positionals, skipping flags (and the values of flags that
// take one).
function positionals(args, valued = new Set()) {
  const out = [];
  let dashdash = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (dashdash || !a.startsWith('-') || a === '-') { out.push(a); continue; }
    if (a === '--') { dashdash = true; continue; }
    if (valued.has(a)) i++;
  }
  return out;
}

const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const listNames = paths => (paths.length <= 3 ? paths.map(basename).join(', ') : plural(paths.length, 'file'));
const where = paths => (paths.length ? (paths.length <= 2 ? `in ${paths.join(', ')}` : `in ${paths.length} paths`) : '');
const range = (a, b) => (b == null || b === a ? `line ${a}` : `lines ${a}–${b}`);

function sedRanges(script) {
  const parts = String(script).split(';').map(s => s.trim()).filter(Boolean);
  const ranges = [];
  for (const p of parts) {
    const m = p.match(/^(\d+)(?:,(\d+|\$))?p$/);
    if (!m) return null;
    ranges.push(m[2] == null ? [m[1]] : [m[1], m[2] === '$' ? 'end' : m[2]]);
  }
  if (!ranges.length) return null;
  if (ranges.length === 1) return range(...ranges[0]);
  return `lines ${ranges.map(([a, b]) => (b == null ? a : `${a}–${b}`)).join(', ')}`;
}

const RG_VALUED = new Set(['-e', '--regexp', '-f', '--file', '-g', '--glob', '--iglob', '-t', '--type', '-T', '--type-not',
  '-m', '--max-count', '-A', '-B', '-C', '--context', '--after-context', '--before-context', '-M', '--max-columns',
  '-j', '--threads', '--sort', '--sortr', '--color', '--colors', '--type-add', '-E', '--encoding', '--max-depth',
  '--maxdepth', '-d', '--include', '--exclude', '--exclude-dir', '-D', '--max-filesize', '--context-separator', '-r', '--replace']);

function classifyArgv(argv, seg = {}) {
  const words = stripPrefixes(argv);
  if (!words.length) return null;
  const cmd = basename(words[0]);
  const args = words.slice(1);
  const out = (seg.redirects || []).find(r => r.op === '>' || r.op === '>>');

  if (out && /^\/dev\//.test(out.target) === false && ['cat', 'echo', 'printf', 'tee'].includes(cmd)) {
    const appending = out.op === '>>';
    const body = seg.heredoc ?? (cmd === 'echo' || cmd === 'printf' ? positionals(args).join(' ') : '');
    return { kind: 'edit', verb: appending ? 'Appended to' : 'Wrote', target: basename(out.target), paths: [out.target],
      ...(body ? { added: body.split('\n').length, diff: body.split('\n').map(text => ({ type: '+', text })) } : {}) };
  }
  if (cmd === 'tee' && positionals(args).length) {
    const files = positionals(args);
    return { kind: 'edit', verb: args.includes('-a') ? 'Appended to' : 'Wrote', target: listNames(files), paths: files };
  }
  if (['cat', 'bat', 'batcat', 'nl', 'less', 'more', 'view'].includes(cmd)) {
    const files = positionals(args, new Set(['-l', '--language', '-r', '--line-range', '-H', '--highlight-line']));
    if (!files.length) return null;
    const r = flagValue(args, ['-r', '--line-range']);
    return { kind: 'read', verb: 'Read', target: listNames(files), paths: files,
      detail: r ? `lines ${r.replace(':', '–')}` : '' };
  }
  if (cmd === 'head' || cmd === 'tail') {
    if (args.includes('-f') || args.includes('-F') || args.includes('--follow')) return null;
    const files = positionals(args, new Set(['-n', '-c', '--lines', '--bytes']));
    if (!files.length) return null;
    let n = flagValue(args, ['-n', '--lines']);
    const short = args.find(a => /^-\d+$/.test(a));
    if (n == null && short) n = short.slice(1);
    n = n == null ? '10' : n.replace(/^\+/, '');
    return { kind: 'read', verb: 'Read', target: listNames(files), paths: files,
      detail: `${cmd === 'head' ? 'first' : 'last'} ${plural(Number(n) || n, 'line')}` };
  }
  if (cmd === 'sed') {
    if (args.some(a => /^-[a-zA-Z]*i/.test(a) || a.startsWith('--in-place'))) {
      const pos = positionals(args, new Set(['-e', '-f']));
      const files = flagValue(args, ['-e']) != null ? pos : pos.slice(1);
      return { kind: 'edit', verb: 'Edited', target: listNames(files), paths: files, detail: 'with sed' };
    }
    if (!args.some(a => /^-[a-zA-Z]*n/.test(a) || a === '--quiet' || a === '--silent')) return null;
    const pos = positionals(args, new Set(['-e', '-f', '--expression']));
    const script = flagValue(args, ['-e', '--expression']) ?? pos.shift();
    if (!pos.length) return null;
    return { kind: 'read', verb: 'Read', target: listNames(pos), paths: pos, detail: sedRanges(script) || '' };
  }
  if (['rg', 'grep', 'egrep', 'fgrep', 'ag', 'ack', 'ripgrep'].includes(cmd)) {
    const pos = positionals(args, RG_VALUED);
    if (cmd === 'rg' && args.includes('--files')) {
      const globs = args.flatMap((a, i) => (a === '-g' || a === '--glob' ? [args[i + 1]] : a.startsWith('--glob=') ? [a.slice(7)] : []));
      return { kind: 'list', verb: pos.length ? 'Listed' : 'Listed files', target: pos.join(', '), paths: pos, code: false,
        detail: globs.length ? `matching ${globs.join(' ')}` : '' };
    }
    const explicit = flagValue(args, ['-e', '--regexp']);
    const pattern = explicit ?? pos.shift();
    if (pattern == null) return null;
    return { kind: 'search', verb: 'Searched for', target: pattern, code: true, paths: pos, detail: where(pos) };
  }
  if (['ls', 'eza', 'exa', 'lsd', 'tree', 'dir'].includes(cmd)) {
    const pos = positionals(args, new Set(['-L', '-I', '--level', '--ignore']));
    return { kind: 'list', verb: 'Listed', target: pos.length ? pos.join(', ') : 'current directory', code: false, paths: pos };
  }
  if (cmd === 'find') {
    const roots = [];
    for (const a of args) { if (/^[-(!]/.test(a)) break; roots.push(a); }
    const name = flagValue(args, ['-name', '-iname', '-path']);
    return { kind: 'list', verb: 'Listed', target: roots.join(', ') || 'current directory', paths: roots, detail: name ? `matching ${name}` : '' };
  }
  if (cmd === 'fd' || cmd === 'fdfind') {
    const pos = positionals(args, new Set(['-e', '--extension', '-t', '--type', '-d', '--max-depth', '-E', '--exclude']));
    const [pattern, ...paths] = pos;
    return { kind: 'list', verb: 'Listed', target: paths.join(', ') || 'current directory', paths,
      detail: pattern ? `matching ${pattern}` : '' };
  }
  if (cmd === 'git') {
    let i = 0;
    let gitCwd;
    while (i < args.length && args[i].startsWith('-')) {
      if (args[i] === '-C') gitCwd = args[i + 1];
      if (['-C', '-c', '--git-dir', '--work-tree'].includes(args[i])) i++;
      i++;
    }
    const sub = args[i];
    if (!sub) return null;
    const rest = positionals(args.slice(i + 1), new Set(['-n', '-m', '--format', '--pretty', '-U']));
    if (sub === 'grep') {
      const pattern = flagValue(args.slice(i + 1), ['-e']) ?? rest.shift();
      return { kind: 'search', verb: 'Searched for', target: pattern ?? '', code: true, paths: rest, detail: where(rest) };
    }
    return { kind: 'git', verb: `Git ${sub}`, target: rest.join(' '), code: true, paths: rest, cwd: gitCwd };
  }
  if (['curl', 'wget', 'http', 'https', 'xh'].includes(cmd)) {
    const url = args.find(a => /^https?:\/\//.test(a));
    if (url) return { kind: 'fetch', verb: 'Fetched', target: url.replace(/^https?:\/\//, ''), paths: [url] };
  }
  return null;
}

/* Patches: Codex `apply_patch` envelopes and unified diffs. */
export function parsePatch(patch) {
  const files = [];
  const lines = [];
  let added = 0;
  let removed = 0;
  for (const line of String(patch ?? '').split('\n')) {
    const env = line.match(/^\*\*\* (Add|Update|Delete) File: (.+)$/);
    const moved = line.match(/^\*\*\* Move to: (.+)$/);
    const uni = line.match(/^\+\+\+ (?:b\/)?(.+)$/);
    if (env) { files.push({ path: env[2].trim(), kind: env[1].toLowerCase() }); lines.push({ type: '@', text: `${env[1]} ${env[2].trim()}` }); continue; }
    if (moved) { if (files.length) files.at(-1).moved = moved[1]; continue; }
    if (uni && uni[1] !== '/dev/null') { files.push({ path: uni[1].trim(), kind: 'update' }); continue; }
    if (/^(?:---|\*\*\* (?:Begin|End) Patch|diff --git|index |\*\*\* End of File)/.test(line)) continue;
    if (line.startsWith('@@')) { lines.push({ type: '@', text: line }); continue; }
    if (line.startsWith('+')) { added++; lines.push({ type: '+', text: line.slice(1) }); }
    else if (line.startsWith('-')) { removed++; lines.push({ type: '-', text: line.slice(1) }); }
    else if (line.startsWith(' ')) lines.push({ type: ' ', text: line.slice(1) });
  }
  return { files, lines, added, removed };
}

// Line diff for old_string → new_string replacements (LCS; bounded).
export function lineDiff(before, after) {
  // A file's final newline terminates its last line; it isn't a line of its own.
  const lines = text => { const l = String(text ?? '').split('\n'); if (l.length > 1 && l.at(-1) === '') l.pop(); return l; };
  const a = lines(before);
  const b = lines(after);
  if (before === '' || before == null) return b.map(text => ({ type: '+', text }));
  if (a.length * b.length > 250000) {
    return [...a.map(text => ({ type: '-', text })), ...b.map(text => ({ type: '+', text }))];
  }
  const dp = Array.from({ length: a.length + 1 }, () => new Uint16Array(b.length + 1));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out = [];
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { out.push({ type: ' ', text: a[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) out.push({ type: '-', text: a[i++] });
    else out.push({ type: '+', text: b[j++] });
  }
  while (i < a.length) out.push({ type: '-', text: a[i++] });
  while (j < b.length) out.push({ type: '+', text: b[j++] });
  return out;
}

const countDiff = lines => ({
  added: lines.filter(l => l.type === '+').length,
  removed: lines.filter(l => l.type === '-').length,
});

/**
 * Describe a shell command as an action: { kind, verb, target, detail, paths,
 * cwd, code }. Wrappers are peeled first; chains of reads collapse into one
 * read; anything else falls back to "Ran <command>".
 */
export function describeCommand(command) {
  const text = unwrapCommand(command);
  const patch = text.match(/^apply_patch\s*(?:<<-?\s*['"]?(\w+)['"]?\n([\s\S]*?)\n\1\s*$|(['"]?)([\s\S]*)\3$)/);
  if (patch || (Array.isArray(command) && command[0] === 'apply_patch')) {
    const body = Array.isArray(command) && command[0] === 'apply_patch' ? command[1] : patch[2] ?? patch[4];
    return { ...describePatch(body), shown: text };
  }
  let commands = parseShell(text);
  let cwd;
  let offset = 0;
  // `cd DIR && …` is context, not the action.
  while (commands.length > 1 && commands[0].pipeline.length === 1) {
    const w = stripPrefixes(commands[0].pipeline[0].words);
    if (w[0] !== 'cd' || !['&&', ';', '\n'].includes(commands[0].op)) break;
    cwd = w[1] ?? '~';
    offset = commands[1].start;
    commands = commands.slice(1);
  }
  const shown = text.slice(offset).trim().replace(/(^|[|;&(\n]\s*)rtk\s+(?:proxy\s+|(?!(?:gain|discover|init|config|help)\b|-))/g, '$1');
  const fallback = { kind: 'run', verb: 'Ran', target: firstLine(shown), code: true, paths: [], detail: cwd ? `in ${cwd}` : '', cwd, shown };

  const pipelines = commands.map(c => c.pipeline);
  const meaningful = pipelines.filter(p => {
    const w = stripPrefixes(p[0].words);
    const redirected = p[0].redirects.some(r => r.op === '>' || r.op === '>>');
    return p.length > 1 || redirected || !NOISE.has(basename(w[0] ?? ''));
  });
  if (!meaningful.length) return fallback;

  const classifyPipeline = p => {
    const first = classifyArgv(p[0].words, p[0]);
    if (!first) return null;
    const filtersOnly = p.slice(1).every(s => FILTERS.has(basename(stripPrefixes(s.words)[0] ?? '')) && !s.redirects.some(r => r.op === '>' || r.op === '>>'));
    return filtersOnly ? first : null;
  };

  if (meaningful.length === 1) {
    const action = classifyPipeline(meaningful[0]);
    if (!action) return fallback;
    return { code: false, detail: '', paths: [], ...action, cwd: action.cwd ?? cwd, shown,
      detail: [action.detail, cwd ? `in ${cwd}` : ''].filter(Boolean).join(' · ') };
  }
  const actions = meaningful.map(classifyPipeline);
  if (actions.every(a => a && a.kind === 'read')) {
    const paths = [...new Set(actions.flatMap(a => a.paths))];
    return { kind: 'read', verb: 'Read', target: listNames(paths), code: false, paths, cwd, shown,
      detail: cwd ? `in ${cwd}` : '' };
  }
  if (actions.every(a => a && a.kind === 'edit')) {
    const paths = [...new Set(actions.flatMap(a => a.paths))];
    const verbs = new Set(actions.map(a => a.verb));
    return { kind: 'edit', verb: verbs.size === 1 ? actions[0].verb : 'Edited', target: listNames(paths), code: false, paths, cwd, shown,
      detail: cwd ? `in ${cwd}` : '', added: actions.reduce((n, a) => n + (a.added || 0), 0) || undefined };
  }
  return fallback;
}

function describePatch(body) {
  const parsed = parsePatch(body);
  const paths = parsed.files.map(f => f.path);
  const only = parsed.files.length === 1 ? parsed.files[0] : null;
  const verb = only?.kind === 'add' ? 'Created' : only?.kind === 'delete' ? 'Deleted' : 'Edited';
  return { kind: 'edit', verb, target: paths.length ? listNames(paths) : 'files', paths, code: false,
    added: parsed.added, removed: parsed.removed, diff: parsed.lines, detail: '' };
}

const norm = name => String(name || '').toLowerCase().replace(/[^a-z0-9]/g, '');
const SHELL_TOOLS = new Set(['bash', 'shell', 'execute', 'exec', 'command', 'commandexecution', 'terminal', 'runterminalcmd',
  'localshell', 'runcommand', 'execcommand', 'runshellcommand', 'containerexec', 'shellcommand', 'unifiedexec']);
const READ_TOOLS = new Set(['read', 'readfile', 'view', 'viewfile', 'openfile', 'fsreadtextfile', 'readtextfile', 'cat', 'readmanyfiles']);
const WRITE_TOOLS = new Set(['write', 'writefile', 'createfile', 'fswritetextfile', 'writetextfile', 'create']);
const EDIT_TOOLS = new Set(['edit', 'multiedit', 'strreplace', 'strreplacebasededittool', 'strreplaceeditor', 'editfile',
  'replace', 'searchreplace', 'notebookedit', 'editnotebook', 'replaceinfile']);
const PATCH_TOOLS = new Set(['applypatch', 'patch', 'filechange', 'applydiff']);
const GREP_TOOLS = new Set(['grep', 'grepsearch', 'search', 'codebasesearch', 'searchfiles', 'ripgrep', 'searchcode', 'searchfilecontent']);
const GLOB_TOOLS = new Set(['glob', 'filesearch', 'findfiles', 'find', 'findpath']);
const LS_TOOLS = new Set(['ls', 'listdir', 'listdirectory', 'listfiles', 'readfolder', 'listfolder']);
const WEB_TOOLS = new Set(['websearch', 'websearchtool', 'searchweb', 'googlesearch', 'websearchcall']);
const FETCH_TOOLS = new Set(['webfetch', 'fetch', 'fetchurl', 'readurl', 'urlfetch', 'browse']);
const PLAN_TOOLS = new Set(['todowrite', 'updateplan', 'todo', 'todoread', 'plan', 'writetodos']);
const AGENT_TOOLS = new Set(['task', 'agent', 'subagent', 'spawnagent']);

const pathOf = input => input.file_path || input.target_file || input.path || input.filePath || input.notebook_path
  || input.absolute_path || input.uri || input.file || input.filename || '';

function readRange(input) {
  const start = input.offset ?? input.start_line ?? input.startLine ?? input.line ?? (Array.isArray(input.view_range) ? input.view_range[0] : undefined);
  const end = input.end_line ?? input.endLine ?? (Array.isArray(input.view_range) ? input.view_range[1] : undefined);
  const limit = input.limit ?? input.max_lines;
  if (start == null && limit == null) return '';
  const from = Number(start ?? 1) || 1;
  if (end != null && end !== -1) return range(from, end);
  if (limit != null) return range(from, from + Number(limit) - 1);
  return `from line ${from}`;
}

function changeKind(c) {
  const k = typeof c.kind === 'string' ? c.kind : c.kind?.type || c.type || '';
  return String(k).toLowerCase();
}

function stringArg(input) {
  for (const k of ['description', 'query', 'prompt', 'url', 'pattern', 'name', 'title', 'path', 'subject']) {
    if (typeof input[k] === 'string' && input[k].trim()) return input[k];
  }
  return '';
}

/** Describe a tool call (any provider) as a verb-first action. */
export function describeTool(tool) {
  const input = parseInput(tool.input);
  const name = tool.name || 'Tool';
  const n = norm(name);
  const command = input.command ?? input.cmd ?? input.commandLine;
  const path = pathOf(input);

  if (Array.isArray(input.changes) && input.changes.length) {
    const diffs = input.changes.map(c => c.diff ?? c.unified_diff ?? c.patch).filter(s => typeof s === 'string');
    const lines = diffs.flatMap(d => parsePatch(d).lines);
    const paths = input.changes.map(c => c.path || c.file_path).filter(Boolean);
    const kinds = input.changes.map(changeKind);
    const verb = kinds.every(k => k === 'add') ? 'Created' : kinds.every(k => k === 'delete') ? 'Deleted' : 'Edited';
    return { kind: 'edit', verb, target: listNames(paths), paths, code: false, detail: '', diff: lines.length ? lines : null,
      ...(lines.length ? countDiff(lines) : {}) };
  }
  if (PATCH_TOOLS.has(n) || (typeof (input.patch ?? input.input) === 'string' && /\*\*\* Begin Patch|^--- |^@@/m.test(input.patch ?? input.input))) {
    return describePatch(input.patch ?? input.input ?? input.diff ?? '');
  }
  if (command && (SHELL_TOOLS.has(n) || !(READ_TOOLS.has(n) || EDIT_TOOLS.has(n) || GREP_TOOLS.has(n)))) {
    const action = describeCommand(command);
    const dir = input.workdir || input.cwd;
    if (action.kind === 'list' && action.target === 'current directory' && dir) return { ...action, target: basename(dir), paths: [dir] };
    return action;
  }
  if (SHELL_TOOLS.has(n)) return { kind: 'run', verb: 'Ran', target: 'command', paths: [], detail: '' };
  if (READ_TOOLS.has(n)) {
    const paths = path ? [path] : Array.isArray(input.paths) ? input.paths : [];
    return { kind: 'read', verb: 'Read', target: paths.length ? listNames(paths) : 'file', paths, detail: readRange(input) };
  }
  const old = input.old_string ?? input.oldText ?? input.old_str ?? input.old;
  const next = input.new_string ?? input.newText ?? input.new_str ?? input.new;
  if (EDIT_TOOLS.has(n) || WRITE_TOOLS.has(n) || typeof old === 'string') {
    let diff = null;
    if (Array.isArray(input.edits)) {
      diff = input.edits.flatMap(e => lineDiff(e.old_string ?? e.oldText ?? '', e.new_string ?? e.newText ?? ''));
    } else if (typeof old === 'string' && typeof next === 'string') diff = lineDiff(old, next);
    else if (typeof input.content === 'string') diff = lineDiff('', input.content);
    else if (typeof input.new_source === 'string') diff = lineDiff('', input.new_source);
    const writing = WRITE_TOOLS.has(n) || (typeof old !== 'string' && !Array.isArray(input.edits) && typeof input.content === 'string');
    return { kind: 'edit', verb: writing ? 'Wrote' : 'Edited', target: path ? basename(path) : 'file', paths: path ? [path] : [],
      detail: input.replace_all ? 'all occurrences' : '', diff, ...(diff ? countDiff(diff) : {}) };
  }
  if (GREP_TOOLS.has(n)) {
    const pattern = input.pattern ?? input.query ?? input.regex ?? input.search ?? '';
    const paths = [input.path || input.directory || input.dir_path].filter(Boolean);
    const glob = input.glob || input.include || input.include_pattern || input.type || '';
    return { kind: 'search', verb: 'Searched for', target: String(pattern), code: true, paths,
      detail: [where(paths), glob ? `(${glob})` : ''].filter(Boolean).join(' ') };
  }
  if (GLOB_TOOLS.has(n)) {
    const pattern = input.pattern ?? input.glob ?? input.query ?? '';
    const paths = [input.path || input.directory].filter(Boolean);
    return { kind: 'list', verb: 'Listed files', target: '', paths, detail: [pattern ? `matching ${pattern}` : '', where(paths)].filter(Boolean).join(' ') };
  }
  if (LS_TOOLS.has(n)) {
    const p = path || input.directory || input.dir_path || input.relative_workspace_path || '';
    return { kind: 'list', verb: 'Listed', target: p || 'directory', paths: p ? [p] : [], detail: '' };
  }
  if (WEB_TOOLS.has(n) || input.type === 'web_search') {
    const q = input.query || input.q || input.action?.query || (Array.isArray(input.action?.queries) ? input.action.queries[0] : '') || '';
    return { kind: 'web', verb: q ? 'Searched the web for' : 'Searched the web', target: q ? `“${q}”` : '', paths: [], detail: '' };
  }
  if (FETCH_TOOLS.has(n)) {
    const url = input.url || input.uri || '';
    return { kind: 'fetch', verb: 'Fetched', target: String(url).replace(/^https?:\/\//, ''), paths: url ? [url] : [], detail: '' };
  }
  if (PLAN_TOOLS.has(n)) return { kind: 'plan', verb: 'Updated the plan', target: '', paths: [], detail: '' };
  if (AGENT_TOOLS.has(n)) {
    return { kind: 'tool', verb: 'Ran agent', target: input.description || input.subagent_type || '', paths: [], detail: '' };
  }
  const mcp = String(name).match(/^mcp__(.+?)__(.+)$/);
  if (mcp) return { kind: 'tool', verb: 'Called', target: `${mcp[1]} · ${mcp[2].replace(/_/g, ' ')}`, paths: [], detail: firstLine(stringArg(input), 80) };
  return { kind: 'tool', verb: name, target: firstLine(stringArg(input) || path, 120), paths: path ? [path] : [], detail: '' };
}

const PROGRESSIVE = { Read: 'Reading', Edited: 'Editing', Wrote: 'Writing', Created: 'Creating', Deleted: 'Deleting',
  'Appended to': 'Appending to', 'Searched for': 'Searching for', 'Listed files': 'Listing files', Listed: 'Listing',
  Fetched: 'Fetching', Ran: 'Running', 'Searched the web for': 'Searching the web for', 'Searched the web': 'Searching the web',
  'Updated the plan': 'Updating the plan', Called: 'Calling', 'Ran agent': 'Running agent' };

/** Present-tense label for a running call: "Reading sessions.rs". */
export function progressiveLabel(action) {
  const verb = PROGRESSIVE[action.verb] ?? (action.verb.startsWith('Git ') ? `Running git ${action.verb.slice(4)}` : action.verb);
  const target = action.kind === 'search' ? `“${action.target}”` : action.target;
  return [verb, target].filter(Boolean).join(' ');
}

/** The line of an error worth showing on a collapsed row. */
const STRONG_ERROR = /No such file|command not found|not found:|Permission denied|\bfatal:|panicked at|Traceback|\bFAILED\b|Connection refused|timed out|^\S+: (?:cannot|can't|unrecognized|invalid)/i;
const ERROR_LINE = /^(?:\S+: )?(?:error|Error|ERROR)(?:\[\w+\])?(?::|$)|Exception\b|not found/;
export function errorSummary(view) {
  const lines = section => section.text.split('\n').map(l => l.trim()).filter(l => l && !/^Exit code \d+$/i.test(l));
  const stderr = view.sections.filter(s => s.error).flatMap(lines);
  const all = view.sections.flatMap(lines);
  const pick = list => {
    if (!list.length) return '';
    if (list.some(l => /^Traceback \(most recent call last\)/.test(l))) return list.at(-1);
    return list.find(l => STRONG_ERROR.test(l)) || list.find(l => ERROR_LINE.test(l)) || '';
  };
  const exit = view.sections.map(s => s.text.match(/^Exit code (\d+)/im)?.[0]).find(Boolean);
  return pick(stderr) || stderr[0] || pick(all) || all.at(-1) || exit || '';
}

const presentCache = new WeakMap();

export function presentTool(tool, turnRunning = false) {
  const cached = presentCache.get(tool);
  if (cached && cached.running === turnRunning) return cached.view;
  const view = buildView(tool, turnRunning);
  presentCache.set(tool, { running: turnRunning, view });
  return view;
}

function buildView(tool, turnRunning) {
  const input = parseInput(tool.input);
  const command = input.command || input.cmd || '';
  const path = pathOf(input);
  const name = tool.name || 'Tool';
  const action = describeTool(tool);
  const kind = { run: 'terminal', git: 'terminal', fetch: 'terminal', read: 'read', search: 'search', list: 'search', edit: 'edit' }[action.kind]
    ?? (command ? 'terminal' : 'tool');
  const title = { terminal: 'Terminal', search: 'Search', edit: 'Edit file', read: 'Read file', tool: name }[kind];
  const changes = Array.isArray(input.changes) ? input.changes : [];
  const summary = command ? displayCommand(command)
    : path || input.pattern || input.query || input.url || input.description
      || changes.map(c => c.path).filter(Boolean).join(', ') || name;
  const sections = [];
  const terminalSections = [];
  const addSection = (label, text, raw, error = false) => {
    sections.push({ label, text, ...(error ? { error: true } : {}) });
    terminalSections.push({ text: typeof raw === 'string' ? raw : JSON.stringify(raw, null, 2), error });
  };
  const stdout = outputText(tool.stdout);
  const stderr = outputText(tool.stderr);
  const output = outputText(tool.output);
  if (stdout) addSection('Output', stdout, tool.stdout);
  if (stderr && stderr !== stdout) addSection('Stderr', stderr, tool.stderr, true);
  if (output && output !== stdout && output !== stderr && output !== [stdout, stderr].filter(Boolean).join('\n')) {
    addSection('Result', output, tool.output);
  }
  let status = tool.ended_ms == null ? (turnRunning ? 'running' : 'interrupted')
    : tool.is_error ? 'failed' : 'completed';
  const lines = sections.reduce((n, s) => n + s.text.trimEnd().split('\n').length, 0);
  // grep/rg exit 1 with nothing printed means "no matches", not a failure.
  const outputBody = sections.map(s => s.text).join('\n').trim();
  const noMatches = action.kind === 'search' && (!outputBody || (status === 'failed' && !stderr && /^Exit code 1$/i.test(outputBody)));
  if (noMatches && status === 'failed') status = 'completed';
  const old = input.old_string ?? input.oldText;
  const next = input.new_string ?? input.newText;
  const replacement = typeof old === 'string' && typeof next === 'string'
    ? { removed: terminalText(old), added: terminalText(next) } : null;
  const content = !replacement && typeof input.content === 'string' ? terminalText(input.content) : '';
  const ms = tool.ended_ms != null && tool.started_ms != null ? Math.max(0, tool.ended_ms - tool.started_ms) : 0;
  const unit = { read: 'line', search: 'match', list: 'entry' }[action.kind];
  const meta = noMatches && status === 'completed' ? 'no matches'
    : unit && lines && status !== 'failed' ? plural(lines, unit, unit === 'match' ? 'matches' : unit === 'entry' ? 'entries' : 'lines') : '';
  const view = { input, command, path, kind, title, summary: String(summary), sections, terminalSections, status,
    replacement, content, lines, duration: duration(tool), durationMs: tool.ended_ms != null && tool.started_ms != null ? ms : null, action,
    label: { verb: action.verb, target: action.target, code: !!action.code, detail: action.detail || '' },
    meta, slow: ms >= 1000 ? duration(tool) : '' };
  view.error = status === 'failed' ? errorSummary(view) || 'Failed' : '';
  return view;
}

/* ── Groups ────────────────────────────────────────────────────────────── */

const PHRASES = {
  read: n => `read ${plural(n, 'file')}`,
  search: n => `searched ${n === 1 ? 'once' : n === 2 ? 'twice' : `${n} times`}`,
  list: n => (n === 1 ? 'listed a directory' : `listed ${n} directories`),
  edit: n => `edited ${plural(n, 'file')}`,
  run: n => `ran ${plural(n, 'command')}`,
  web: n => (n === 1 ? 'searched the web' : `searched the web ${n} times`),
  fetch: n => (n === 1 ? 'fetched a page' : `fetched ${n} pages`),
  plan: () => 'updated the plan',
  tool: n => `used ${plural(n, 'tool')}`,
};

/** "Read 4 files, searched once, ran 1 command · 1 failed". */
export function summarizeTools(views) {
  const buckets = new Map();
  for (const v of views) {
    const kind = v.action.kind === 'git' ? 'run' : v.action.kind;
    if (!buckets.has(kind)) buckets.set(kind, { count: 0, files: new Set(), unnamed: 0 });
    const b = buckets.get(kind);
    b.count++;
    if (kind === 'read' || kind === 'edit') {
      if (v.action.paths?.length) v.action.paths.forEach(p => b.files.add(p)); else b.unnamed++;
    }
  }
  const parts = [...buckets].map(([kind, b]) =>
    PHRASES[kind](kind === 'read' || kind === 'edit' ? b.files.size + b.unnamed : b.count));
  let text = parts.join(', ');
  text = text.charAt(0).toUpperCase() + text.slice(1);
  const failed = views.filter(v => v.status === 'failed').length;
  return failed ? `${text} · ${failed} failed` : text;
}

// Bound the painted DOM as well as its viewport. The inspector retains the
// full saved tool row; thousands of lines never become thousands of spans.
export function clipText(text, limit = 48000) {
  if (text.length <= limit) return { text, clipped: false };
  let end = limit;
  if (/[\uD800-\uDBFF]/.test(text[end - 1])) end--;
  return { text: text.slice(0, end), clipped: true };
}

/* Row geometry (rows live in fixed-height Escape boxes). */
export const ROW_HEIGHT = 30;
export const MORE_HEIGHT = 30;
