import test from 'node:test'
import assert from 'node:assert/strict'
import { parseAnsi, stripAnsi } from '../src/lib/ansi.ts'
import { diffStat, hunks, lineDiff } from '../src/lib/diff.ts'
import { sanitizeUrl } from '../src/lib/sanitize.ts'
import {
  applyUtf8Splices,
  changedLinesFromSplices,
  computeUtf8Splices,
  utf16ToUtf8Offset,
  utf8ToUtf16Offset,
} from '../src/lib/splices.ts'
import { displayCommand, parseInput, presentTool, summarizeTools } from '../src/lib/tools.ts'
import {
  canAttenuateAccess,
  formatBudgetSummary,
  groupThreadsByHierarchy,
  spaceStateBadgeVariant,
  summarizeHealth,
  taskStatusBadgeVariant,
  threadModeLabel,
  validateSubordinateGrants,
} from '../src/lib/v2.ts'

test('ansi strips and parses SGR colors, 256-color, RGB, reset, and carriage returns', () => {
  assert.equal(stripAnsi('\x1b[31merror\x1b[0m: ok'), 'error: ok')
  assert.equal(stripAnsi('step 1\rstep 2\ndone'), 'step 2\ndone')

  const lines = parseAnsi('\x1b[1;32mPASS\x1b[0m \x1b[38;5;196mred256\x1b[0m \x1b[38;2;10;20;30mrgb\x1b[0m')
  assert.equal(lines.length, 1)
  assert.equal(lines[0][0].text, 'PASS')
  assert.equal(lines[0][0].style?.bold, true)
  assert.equal(lines[0][0].style?.fg, 2)
  assert.equal(lines[0][2].text, 'red256')
  assert.equal(lines[0][2].style?.fg, 'rgb(255,0,0)')
  assert.equal(lines[0][4].text, 'rgb')
  assert.equal(lines[0][4].style?.fg, 'rgb(10,20,30)')
})

test('diff computes line diffs, hunks, and stats', () => {
  const before = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].join('\n')
  const after = ['a', 'b', 'C', 'd', 'e', 'f', 'g', 'h', 'i'].join('\n')
  const rows = lineDiff(before, after)
  const stat = diffStat(rows)
  assert.deepEqual(stat, { added: 2, removed: 1 })

  const hs = hunks(rows, 1)
  assert.equal(hs.length, 2)
  assert.ok(hs[0].lines.some(r => r.kind === 'del' && r.text === 'c'))
  assert.ok(hs[0].lines.some(r => r.kind === 'add' && r.text === 'C'))
  assert.ok(hs[1].lines.some(r => r.kind === 'add' && r.text === 'i'))
})

test('splices roundtrip UTF-8 offsets, applyUtf8Splices, changedLinesFromSplices, and computeUtf8Splices', () => {
  const text = 'hello 🚀 world\nline2'
  const u8 = utf16ToUtf8Offset(text, 8)
  assert.equal(u8, 10)
  assert.equal(utf8ToUtf16Offset(text, u8), 8)

  const patched = applyUtf8Splices(text, [{ at: 6, del: 4, text: '✨' }])
  assert.equal(patched, 'hello ✨ world\nline2')
  assert.deepEqual(changedLinesFromSplices(patched, [{ at: 6, del: 4, text: '✨' }]), [0])

  const before = 'alpha\n🚀 beta\ngamma\n'
  const after = 'alpha\n🔥 BETA\ndelta\ngamma\n'
  const computed = computeUtf8Splices(before, after)
  assert.equal(computed.splices.length, 1)
  const rebuilt = applyUtf8Splices(
    before,
    computed.splices.map(s => ({ at: s.at, del: s.del, text: computed.inserted })),
  )
  assert.equal(rebuilt, after)

  const same = computeUtf8Splices(before, before)
  assert.equal(same.splices.length, 0)
  assert.equal(same.inserted, '')
})

test('tools parses inputs, strips shell wrappers, presents and summarizes tool calls', () => {
  assert.deepEqual(parseInput('{"command":"git status"}'), { command: 'git status' })
  assert.deepEqual(parseInput('raw input'), { input: 'raw input' })
  assert.equal(displayCommand("/bin/zsh -lc 'echo hi'"), 'echo hi')

  const v1 = presentTool(
    {
      id: 't1',
      name: 'bash',
      input: JSON.stringify({ command: 'ls -la' }),
      output: '\x1b[32mok\x1b[0m',
      is_error: false,
      started_ms: 1000,
      ended_ms: 1250,
    },
    false,
  )
  assert.equal(v1.kind, 'run')
  assert.equal(v1.status, 'done')
  assert.equal(v1.outputPlain, 'ok')

  const v2 = presentTool(
    {
      id: 't2',
      name: 'read_file',
      input: JSON.stringify({ path: 'src/main.zig' }),
      output: 'const x = 1;',
      is_error: false,
      started_ms: 1250,
      ended_ms: 1300,
    },
    false,
  )
  const v3 = presentTool(
    {
      id: 't3',
      name: 'read_file',
      input: JSON.stringify({ path: 'src/lib.zig' }),
      output: 'pub const y = 2;',
      is_error: false,
      started_ms: 1300,
      ended_ms: 1350,
    },
    false,
  )
  assert.equal(v2.kind, 'read')
  assert.equal(summarizeTools([v1, v2]), 'Ran ls -la, read main.zig')
  assert.equal(summarizeTools([v2, v2]), 'Read main.zig')
  assert.equal(summarizeTools([v2, v3]), 'Read main.zig, lib.zig')
})

test('sanitizeUrl allows safe protocols and relative links and rejects XSS schemes', () => {
  assert.equal(sanitizeUrl('https://example.com/docs?a=1#top'), 'https://example.com/docs?a=1#top')
  assert.equal(sanitizeUrl('http://127.0.0.1:8080/x'), 'http://127.0.0.1:8080/x')
  assert.equal(sanitizeUrl('mailto:dev@example.com'), 'mailto:dev@example.com')
  assert.equal(sanitizeUrl('#section-1'), '#section-1')
  assert.equal(sanitizeUrl('/api/info'), '/api/info')

  assert.equal(sanitizeUrl('javascript:alert(1)'), null)
  assert.equal(sanitizeUrl('JaVaScRiPt:alert(1)'), null)
  assert.equal(sanitizeUrl('java\tscript:alert(1)'), null)
  assert.equal(sanitizeUrl('  javascript:alert(1)'), null)
  assert.equal(sanitizeUrl('data:text/html,<script>alert(1)</script>'), null)
  assert.equal(sanitizeUrl('vbscript:msgbox(1)'), null)
  assert.equal(sanitizeUrl('//evil.example/x'), null)
  assert.equal(sanitizeUrl('/\\evil.example/x'), null)
  assert.equal(sanitizeUrl(''), null)
  assert.equal(sanitizeUrl(null), null)
  assert.equal(sanitizeUrl(undefined), null)
})

test('v2 access attenuation prevents privilege escalation and allows monotonic narrowing', () => {
  assert.equal(canAttenuateAccess('shared_rw', 'shared_rw'), true)
  assert.equal(canAttenuateAccess('shared_rw', 'isolated_fork'), true)
  assert.equal(canAttenuateAccess('shared_rw', 'read_only'), true)
  assert.equal(canAttenuateAccess('isolated_fork', 'isolated_fork'), true)
  assert.equal(canAttenuateAccess('isolated_fork', 'read_only'), true)
  assert.equal(canAttenuateAccess('isolated_fork', 'shared_rw'), false)
  assert.equal(canAttenuateAccess('read_only', 'read_only'), true)
  assert.equal(canAttenuateAccess('read_only', 'isolated_fork'), false)
  assert.equal(canAttenuateAccess('read_only', 'shared_rw'), false)

  const parent = [
    { space_id: 's1', alias: 'notes', access: 'read_only' as const },
    { space_id: 's2', alias: 'api', access: 'shared_rw' as const },
  ]
  assert.deepEqual(validateSubordinateGrants(parent, [{ space_id: 's2', alias: 'api', access: 'isolated_fork' }]), { ok: true })
  const escalated = validateSubordinateGrants(parent, [{ space_id: 's1', alias: 'notes', access: 'shared_rw' }])
  assert.equal(escalated.ok, false)
  const unbound = validateSubordinateGrants(parent, [{ space_id: 's3', alias: 'other', access: 'read_only' }])
  assert.equal(unbound.ok, false)
})

test('v2 thread mode, hierarchy grouping, badges, budget, and health summaries', () => {
  assert.equal(threadModeLabel([]), 'Zero-Repo')
  assert.equal(threadModeLabel([{ space_id: 's1' }]), '1 Space')
  assert.equal(threadModeLabel([{ space_id: 's1' }, { space_id: 's2' }]), '2 Spaces')

  assert.equal(spaceStateBadgeVariant('hot'), 'ok')
  assert.equal(spaceStateBadgeVariant('warm'), 'amber')
  assert.equal(spaceStateBadgeVariant('cold'), 'outline')

  assert.equal(taskStatusBadgeVariant('completed'), 'ok')
  assert.equal(taskStatusBadgeVariant('failed'), 'danger')
  assert.equal(taskStatusBadgeVariant('running'), 'violet')
  assert.equal(taskStatusBadgeVariant('ready'), 'amber')

  assert.equal(
    formatBudgetSummary({
      max_tokens: 5000,
      used_tokens: 250,
      max_cost_microusd: 0,
      used_cost_microusd: 0,
      max_wall_ms: 0,
      used_wall_ms: 0,
      max_depth: 4,
      max_children: 8,
      active_children: 2,
    }),
    '250/5000 tok · 2/8 workers · depth ≤ 4',
  )

  const summary = summarizeHealth({
    ok: true,
    open_spaces: 2,
    total_spaces: 5,
    hot_spaces: 1,
    warm_spaces: 1,
    cold_spaces: 3,
    hibernated_spaces: 4,
    projects_count: 1,
    threads_count: 3,
    memory_governor_bytes: 20480,
    workspace_bytes: 16384,
    blob_bytes: 4096,
    git_delta_bytes: 0,
    watcher_fds: 4,
    watch_count: 12,
    runner_id: 'r1',
    device_id: 'd1',
  })
  assert.deepEqual(summary, {
    spacesLabel: '1 hot · 4 hibernated',
    governorKb: 20,
    watcherLabel: '4 FDs / 12 watches',
  })

  const ordered = groupThreadsByHierarchy([
    { thread_id: 'child-1', parent_thread_id: 'root-1', depth: 1, title: 'Worker 1' },
    { thread_id: 'root-1', parent_thread_id: null, depth: 0, title: 'Captain' },
    { thread_id: 'grandchild-1', parent_thread_id: 'child-1', depth: 2, title: 'Subworker' },
  ])
  assert.deepEqual(
    ordered.map(r => [r.thread.thread_id, r.indent]),
    [
      ['root-1', 0],
      ['child-1', 1],
      ['grandchild-1', 2],
    ],
  )
})
