import test from 'node:test';
import assert from 'node:assert/strict';
import { presentTool, terminalText, displayCommand, clipText } from './toolPresentation.js';

const tool = (overrides = {}) => ({ name: 'Bash', input: '{}', started_ms: 1000, ended_ms: 2300, ...overrides });

test('saved CLI output is readable and duplicated combined output is omitted', () => {
  const v = presentTool(tool({ input: JSON.stringify({command: '/bin/zsh -lc "npm test"'}),
    stdout: '\x1b[32m✓ passed\x1b[0m\n', output: '\x1b[32m✓ passed\x1b[0m\n' }));
  assert.equal(v.kind, 'terminal');
  assert.equal(v.summary, 'npm test');
  assert.equal(v.command, '/bin/zsh -lc "npm test"');
  assert.deepEqual(v.sections, [{ label: 'Output', text: '✓ passed\n' }]);
  assert.equal(v.duration, '1.3s');
});

test('stderr and failures remain visible, including stale running calls', () => {
  const v = presentTool(tool({ stdout: 'partial', stderr: 'failed', output: 'partial\nfailed', is_error: true }));
  assert.equal(v.status, 'failed');
  assert.equal(v.sections.length, 2);
  assert.equal(v.sections[1].error, true);
  assert.equal(presentTool(tool({ ended_ms: null }), true).status, 'running');
  assert.equal(presentTool(tool({ ended_ms: null }), false).status, 'interrupted');
});

test('read, search and replacement cards use normalized arguments', () => {
  assert.equal(presentTool(tool({ name: 'read_file', input: '{"target_file":"src/app.rs"}' })).summary, 'src/app.rs');
  assert.equal(presentTool(tool({ name: 'Grep', input: '{"pattern":"TODO"}' })).kind, 'search');
  const edit = presentTool(tool({ name: 'Edit', input: '{"file_path":"a.ts","old_string":"a","new_string":"b"}' }));
  assert.deepEqual(edit.replacement, { removed: 'a', added: 'b' });
  assert.equal(edit.kind, 'edit');
  assert.equal(presentTool(tool({ name: 'Other', input: 'invalid json' })).input.input, 'invalid json');
});

test('terminal escapes are inert and progress frames collapse correctly', () => {
  assert.equal(terminalText('\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\\n10%\r100%\r\n'), 'link\n100%\n');
  assert.equal(terminalText('<script>alert(1)</script>'), '<script>alert(1)</script>');
  assert.equal(displayCommand("/bin/bash -lc 'echo hi'"), 'echo hi');
  assert.equal(displayCommand('echo "hello"'), 'echo "hello"');
});

test('large output and surrogate pairs are bounded, viewport never grows unbounded', () => {
  assert.equal(clipText('abc😀xyz', 4).text, 'abc');
  assert.equal(clipText('hello', 10).clipped, false);
  const v = presentTool(tool({ stdout: 'hello\n'.repeat(100000) }));
  assert.equal(clipText(v.sections[0].text).text.length, 48000);
});

/* ── Command classifier ─────────────────────────────────────────────────── */
import { describeCommand, describeTool, unwrapCommand, cleanCommand, parseShell, summarizeTools, progressiveLabel, errorSummary, lineDiff } from './toolPresentation.js';

const label = a => [a.verb, a.target, a.detail].filter(Boolean).join(' | ');

test('sed -n ranges read as "Read FILE · lines a–b", through zsh and rtk wrappers', () => {
  const a = describeCommand(`/bin/zsh -lc "rtk proxy sed -n '470,640p' crates/ondb-agents/src/sessions.rs"`);
  assert.equal(a.kind, 'read');
  assert.equal(label(a), 'Read | sessions.rs | lines 470–640');
  assert.deepEqual(a.paths, ['crates/ondb-agents/src/sessions.rs']);
  assert.equal(describeCommand("sed -n '648,710p;740,825p' a/b.rs").detail, 'lines 648–710, 740–825');
  assert.equal(describeCommand("sed -n '12p' x.txt").detail, 'line 12');
  assert.equal(describeCommand("sed -n '5,$p' x.txt").detail, 'lines 5–end');
  // A transforming sed is not a read; sed -i is an edit.
  assert.equal(describeCommand("sed 's/a/b/' x.txt").kind, 'run');
  assert.equal(describeCommand("sed -i '' 's/a/b/' x.txt").kind, 'edit');
});

test('rtk, zsh/bash -lc and nested sh -c wrappers are peeled', () => {
  assert.equal(unwrapCommand("/bin/zsh -lc 'rtk cat todo.md'"), 'rtk cat todo.md');
  assert.equal(label(describeCommand("/bin/zsh -lc 'rtk cat todo.md'")), 'Read | todo.md');
  assert.equal(label(describeCommand(`bash -lc "rtk proxy sh -c 'cat /Users/me/.codex/RTK.md'"`)), 'Read | RTK.md');
  assert.equal(label(describeCommand(['/bin/zsh', '-lc', 'rtk proxy head -n 20 README.md'])), 'Read | README.md | first 20 lines');
  assert.equal(label(describeCommand('rtk read src/main.rs')), 'Read | main.rs');
  assert.equal(cleanCommand(`/bin/zsh -lc "rtk proxy python3 -c 'print(1)'"`), "python3 -c 'print(1)'");
  // rtk's own meta commands are not wrappers.
  assert.equal(label(describeCommand('rtk gain')), 'Ran | rtk gain');
  assert.equal(describeCommand(`/bin/zsh -lc "rtk proxy sh -c 'command -v luau; command -v lua'"`).target, 'command -v luau; command -v lua');
});

test('a leading cd DIR && becomes context', () => {
  const a = describeCommand('cd crates/ondb && rg -n "fn main" src');
  assert.equal(a.kind, 'search');
  assert.equal(a.cwd, 'crates/ondb');
  assert.equal(label(a), 'Searched for | fn main | in src · in crates/ondb');
  const run = describeCommand('cd ui && npm run build');
  assert.equal(label(run), 'Ran | npm run build | in ui');
});

test('rg/grep patterns and paths; rg --files lists', () => {
  const a = describeCommand(`rtk proxy rg -n 'pub fn|adopt' crates/ondb/src/worktrees.rs`);
  assert.equal(a.kind, 'search');
  assert.equal(a.target, 'pub fn|adopt');
  assert.equal(a.code, true);
  assert.equal(a.detail, 'in crates/ondb/src/worktrees.rs');
  assert.equal(describeCommand('grep -rn -A 3 TODO src lib').detail, 'in src, lib');
  assert.equal(describeCommand('grep -rn -A 3 TODO src lib').target, 'TODO');
  assert.equal(describeCommand('rg -e foo -g "*.rs" a b c').detail, 'in 3 paths');
  assert.equal(describeCommand('rg -e foo -g "*.rs" a b c').target, 'foo');
  assert.equal(label(describeCommand('rg --files crates/engine | head -150')), 'Listed | crates/engine');
  assert.equal(label(describeCommand('ls -la crates/ondb/src')), 'Listed | crates/ondb/src');
  assert.equal(label(describeCommand("find . -name '*.rs'")), 'Listed | . | matching *.rs');
});

test('git, fetch, chains and fallbacks', () => {
  assert.equal(label(describeCommand("/bin/zsh -lc 'rtk git status --short'")), 'Git status');
  assert.equal(label(describeCommand('git -C repo diff src/a.rs')), 'Git diff | src/a.rs');
  assert.equal(describeCommand('curl -fsS https://pokeapi.co/api/v2/pokemon/pikachu -o /tmp/p.json').kind, 'fetch');
  assert.equal(label(describeCommand('cargo test -p ondb')), 'Ran | cargo test -p ondb');
  // Reads chained with echo separators collapse to one read.
  assert.equal(label(describeCommand('cat README.md; echo ==; cat main.rs')), 'Read | README.md, main.rs');
  // Mixed chains fall back to the command, wrappers stripped, first line only.
  const mixed = describeCommand("cat todo.md && echo '- [ ] x' >> todo.md && git add todo.md");
  assert.equal(mixed.kind, 'run');
  assert.equal(mixed.target, "cat todo.md && echo '- [ ] x' >> todo.md && git add todo.md");
  assert.equal(describeCommand('python3 - <<EOF\nprint(1)\nEOF').target, 'python3 - <<EOF …');
});

test('heredoc and redirect writes are edits', () => {
  const a = describeCommand("cat > notes.md <<'EOF'\n# Notes\n\nhello\nEOF");
  assert.equal(label(a), 'Wrote | notes.md');
  assert.equal(a.added, 3);
  assert.equal(label(describeCommand("echo '- [ ] Test' >> todo.md")), 'Appended to | todo.md');
  const multi = describeCommand("cat > a.md <<'EOF'\nA\nEOF\ncat > b.md <<'EOF'\nB\nEOF");
  assert.equal(label(multi), 'Wrote | a.md, b.md');
});

test('parseShell honours quotes, operators and heredoc bodies', () => {
  const cmds = parseShell(`a "x && y" && b 'c;d' | e; f 2>&1 > out.txt`);
  assert.deepEqual(cmds.map(c => c.pipeline.map(s => s.words)), [[['a', 'x && y']], [['b', 'c;d'], ['e']], [['f']]]);
  assert.deepEqual(cmds[2].pipeline[0].redirects, [{ op: '>', target: 'out.txt' }]);
  const doc = parseShell("cat > f <<'EOF'\nls && rm -rf /\nEOF\necho done");
  assert.equal(doc.length, 2);
  assert.equal(doc[0].pipeline[0].heredoc, 'ls && rm -rf /');
});

test('native tools map to the same verbs', () => {
  const t = (name, input) => describeTool({ name, input: JSON.stringify(input) });
  assert.equal(label(t('Read', { file_path: '/repo/docs/ROADMAP.md', offset: 10, limit: 20 })), 'Read | ROADMAP.md | lines 10–29');
  assert.equal(label(t('read_file', { target_file: '/w/story.md' })), 'Read | story.md');
  assert.equal(label(t('Grep', { pattern: 'TODO', path: 'src', glob: '*.ts' })), 'Searched for | TODO | in src (*.ts)');
  assert.equal(label(t('Glob', { pattern: '**/*.rs' })), 'Listed files | matching **/*.rs');
  assert.equal(label(t('WebSearch', { query: 'xterm themes' })), 'Searched the web for | “xterm themes”');
  assert.equal(label(t('WebSearch', { action: { type: 'other' }, query: '', type: 'web_search' })), 'Searched the web');
  assert.equal(t('mcp__linear__get_issue', { id: 'ABC-1' }).verb, 'Called');
  assert.equal(label(t('execute', { command: 'ls', workdir: '/w/demo-work' })), 'Listed | demo-work');
  assert.equal(t('TodoWrite', { todos: [] }).kind, 'plan');
});

test('edits carry +/− counts from replacements, writes and patches', () => {
  const t = (name, input) => describeTool({ name, input: JSON.stringify(input) });
  const edit = t('Edit', { file_path: '/r/src/a.ts', old_string: 'a\nb\nc', new_string: 'a\nB\nc\nd' });
  assert.equal(label(edit), 'Edited | a.ts');
  assert.deepEqual([edit.added, edit.removed], [2, 1]);
  assert.deepEqual(edit.diff.map(l => l.type), [' ', '-', '+', ' ', '+']);
  const write = t('Write', { file_path: 'notes.md', content: 'one\ntwo\n' });
  assert.equal(label(write), 'Wrote | notes.md');
  assert.equal(write.added, 2);
  const multi = t('MultiEdit', { file_path: 'x.rs', edits: [{ old_string: 'a', new_string: 'b' }, { old_string: 'c', new_string: 'd\ne' }] });
  assert.deepEqual([multi.added, multi.removed], [3, 2]);
  const patch = '*** Begin Patch\n*** Update File: src/lib.rs\n@@ fn main\n-old\n+new\n+more\n context\n*** End Patch';
  const p = t('apply_patch', { input: patch });
  assert.equal(label(p), 'Edited | lib.rs');
  assert.deepEqual([p.added, p.removed], [2, 1]);
  assert.equal(label(describeCommand(['apply_patch', '*** Begin Patch\n*** Add File: new.txt\n+hi\n*** End Patch'])), 'Created | new.txt');
  const codex = t('Edit', { changes: [{ kind: 'add', path: '/w/pokemon.luau' }] });
  assert.equal(label(codex), 'Created | pokemon.luau');
  assert.deepEqual(lineDiff('', 'x'), [{ type: '+', text: 'x' }]);
});

test('failures surface the error line; rg with no matches is quiet', () => {
  const fail = presentTool(tool({ input: JSON.stringify({ command: `/bin/zsh -lc "rtk proxy cat a.rs b.md"` }), is_error: 1,
    output: 'Exit code 1\nuse crate::Error;\n    error: Option<String>,\ncat: b.md: No such file or directory' }));
  assert.equal(fail.status, 'failed');
  assert.equal(fail.error, 'cat: b.md: No such file or directory');
  const py = presentTool(tool({ is_error: 1, stderr: 'Traceback (most recent call last):\n  File "<string>"\nurllib.error.HTTPError: HTTP Error 403' }));
  assert.equal(py.error, 'urllib.error.HTTPError: HTTP Error 403');
  const none = presentTool(tool({ input: JSON.stringify({ command: 'rg -n zzz src' }), is_error: 1, output: '' }));
  assert.equal(none.status, 'completed');
  assert.equal(none.meta, 'no matches');
  assert.equal(errorSummary({ sections: [] }), '');
});

test('rows show durations only from 1s; reads/searches count lines', () => {
  const quick = presentTool(tool({ input: JSON.stringify({ command: "sed -n '1,3p' a.rs" }), stdout: 'a\nb\nc\n', ended_ms: 1011 }));
  assert.equal(quick.slow, '');
  assert.equal(quick.duration, '11 ms');
  assert.equal(quick.meta, '3 lines');
  assert.equal(presentTool(tool({ stdout: 'ok' })).slow, '1.3s');
});

test('group headers summarise semantically', () => {
  const v = c => presentTool(tool({ input: JSON.stringify({ command: c }), stdout: 'x' }));
  const views = [v("sed -n '1,9p' a.rs"), v('cat b.rs'), v("sed -n '20,30p' a.rs"), v('rg foo src'), v('cargo test'),
    presentTool(tool({ input: JSON.stringify({ command: 'false' }), is_error: 1, stderr: 'boom' }))];
  assert.equal(summarizeTools(views), 'Read 2 files, searched once, ran 2 commands · 1 failed');
  assert.equal(summarizeTools([v('ls src'), v('ls lib'), v('rg a'), v('rg b')]), 'Listed 2 directories, searched twice');
  assert.equal(progressiveLabel(describeCommand("sed -n '1,2p' crates/x/sessions.rs")), 'Reading sessions.rs');
  assert.equal(progressiveLabel(describeCommand('rg -n foo')), 'Searching for “foo”');
});
