import type { TraceTool } from './api'
import { stripAnsi } from './ansi'
import { duration } from './format'

export type ToolKind = 'run' | 'read' | 'write' | 'edit' | 'search' | 'list' | 'web' | 'fetch' | 'plan' | 'agent' | 'tool'
export type ToolStatus = 'running' | 'done' | 'failed' | 'interrupted'

export interface ToolView {
  kind: ToolKind
  status: ToolStatus
  verb: string
  progressive: string
  target: string
  detail: string
  code: boolean
  command: string | null
  path: string | null
  input: Record<string, unknown>
  rawInput: string
  output: string
  outputPlain: string
  content: string | null
  edit: { before: string; after: string } | null
  time: string
  added: number
  removed: number
}

const norm = (name: string) => name.split(/[·:(]/)[0].trim().toLowerCase().replace(/[^a-z]/g, '')

const SETS: [ToolKind, string[]][] = [
  ['run', ['bash', 'shell', 'execute', 'exec', 'command', 'commandexecution', 'terminal', 'runterminalcmd', 'execcommand', 'runshellcommand', 'localshell', 'run']],
  ['read', ['read', 'readfile', 'view', 'viewfile', 'openfile', 'fsreadtextfile', 'readtextfile', 'cat', 'readmanyfiles']],
  ['write', ['write', 'writefile', 'createfile', 'fswritetextfile', 'writetextfile', 'create']],
  ['edit', ['edit', 'multiedit', 'strreplace', 'strreplacebasededittool', 'editfile', 'applypatch', 'patch', 'filechange', 'applydiff', 'replace']],
  ['search', ['grep', 'grepsearch', 'search', 'codebasesearch', 'searchfiles', 'ripgrep', 'searchcode', 'glob', 'filesearch', 'findfiles', 'find']],
  ['list', ['ls', 'listdir', 'listdirectory', 'listfiles', 'readfolder']],
  ['web', ['websearch', 'searchweb', 'googlesearch']],
  ['fetch', ['webfetch', 'fetch', 'fetchurl', 'readurl', 'browse']],
  ['plan', ['todowrite', 'updateplan', 'todo', 'plan', 'writetodos']],
  ['agent', ['task', 'agent', 'subagent', 'spawnagent']],
]

const VERBS: Record<ToolKind, [string, string]> = {
  run: ['Ran', 'Running'],
  read: ['Read', 'Reading'],
  write: ['Wrote', 'Writing'],
  edit: ['Edited', 'Editing'],
  search: ['Searched', 'Searching'],
  list: ['Listed', 'Listing'],
  web: ['Searched the web', 'Searching the web'],
  fetch: ['Fetched', 'Fetching'],
  plan: ['Updated plan', 'Planning'],
  agent: ['Delegated', 'Delegating'],
  tool: ['Called', 'Calling'],
}

export function parseInput(raw: string): Record<string, unknown> {
  if (!raw) return {}
  try {
    const v = JSON.parse(raw)
    if (v && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>
    return { value: v }
  } catch {
    return { input: raw }
  }
}

const str = (v: unknown) => (typeof v === 'string' ? v : v == null ? '' : Array.isArray(v) ? v.map(String).join(' ') : JSON.stringify(v))
const pick = (o: Record<string, unknown>, keys: string[]) => {
  for (const k of keys) if (o[k] != null && o[k] !== '') return o[k]
  return undefined
}
export const basename = (p: string) => p.replace(/\/+$/, '').split('/').at(-1) || p

export function displayCommand(command: unknown): string {
  if (Array.isArray(command)) {
    const argv = command.map(String)
    if (argv.length === 3 && /(^|\/)(ba|z|da|k|fi)?sh$/.test(argv[0]) && /^-[a-z]*c[a-z]*$/.test(argv[1])) return argv[2]
    return argv.map(a => (/^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)).join(' ')
  }
  const text = String(command ?? '')
  const m = text.match(/^(?:\/\S*\/)?(?:zsh|bash|sh)\s+-[a-z]*c\s+(["'])([\s\S]*)\1$/)
  return m ? m[2] : text
}

function classify(name: string, input: Record<string, unknown>): ToolKind {
  const n = norm(name)
  for (const [kind, names] of SETS) if (names.includes(n)) return kind
  if (pick(input, ['command', 'cmd'])) return 'run'
  if (pick(input, ['old_string', 'oldString', 'patch', 'diff'])) return 'edit'
  if (pick(input, ['content']) && pick(input, ['file_path', 'path'])) return 'write'
  if (pick(input, ['file_path', 'path', 'filePath'])) return 'read'
  if (pick(input, ['url'])) return 'fetch'
  if (pick(input, ['pattern', 'query'])) return 'search'
  return 'tool'
}

function firstLine(text: string, max = 120) {
  const line = text.split('\n').find(l => l.trim()) ?? ''
  return line.length > max ? `${line.slice(0, max - 1)}…` : line
}

function countLines(s: string) {
  if (!s) return 0
  return s.replace(/\n$/, '').split('\n').length
}

export function presentTool(tool: TraceTool, turnStreaming: boolean): ToolView {
  const input = parseInput(tool.input)
  const kind = classify(tool.name, input)
  const status: ToolStatus = tool.is_error ? 'failed' : tool.ended_ms != null ? 'done' : turnStreaming ? 'running' : 'interrupted'
  const output = tool.output ?? ''
  const outputPlain = stripAnsi(output)
  const [verbDone, verbIng] = VERBS[kind]
  const nameTail = tool.name.includes('·') ? tool.name.split('·').slice(1).join('·').trim() : ''
  let target = ''
  let detail = ''
  let code = false
  let command: string | null = null
  let path: string | null = null
  let content: string | null = null
  let edit: ToolView['edit'] = null
  let added = 0
  let removed = 0

  const p = str(pick(input, ['file_path', 'path', 'filePath', 'filename', 'notebook_path']))
  if (kind === 'run') {
    command = displayCommand(pick(input, ['command', 'cmd', 'input']) ?? nameTail)
    target = firstLine(command)
    code = true
    detail = str(pick(input, ['description']))
  } else if (kind === 'read' || kind === 'write' || kind === 'edit') {
    path = p || nameTail || null
    target = path ? basename(path) : ''
    if (kind === 'write') {
      content = str(pick(input, ['content', 'text']))
      added = countLines(content)
      if (added) detail = `${added} line${added === 1 ? '' : 's'}`
    }
    if (kind === 'edit') {
      const before = str(pick(input, ['old_string', 'oldString', 'old_str']))
      const after = str(pick(input, ['new_string', 'newString', 'new_str']))
      if (before || after) {
        edit = { before, after }
        added = countLines(after)
        removed = countLines(before)
      }
    }
    if (kind === 'read') {
      const off = pick(input, ['offset', 'line', 'start_line'])
      const lim = pick(input, ['limit'])
      if (off != null) detail = `from line ${off}${lim ? `, ${lim} lines` : ''}`
    }
  } else if (kind === 'search') {
    target = str(pick(input, ['pattern', 'query', 'glob', 'regex']))
    code = true
    const where = str(pick(input, ['path', 'include', 'glob']))
    if (where && where !== target) detail = `in ${where}`
  } else if (kind === 'list') {
    target = p || 'current directory'
  } else if (kind === 'web') {
    target = str(pick(input, ['query', 'q']))
  } else if (kind === 'fetch') {
    target = str(pick(input, ['url'])).replace(/^https?:\/\//, '')
  } else if (kind === 'agent') {
    target = str(pick(input, ['description', 'prompt'])).slice(0, 80)
  } else {
    target = nameTail || tool.name
  }

  const ms = tool.ended_ms != null && tool.started_ms ? tool.ended_ms - tool.started_ms : null
  return {
    kind,
    status,
    verb: kind === 'tool' ? tool.name.split('·')[0].trim() : verbDone,
    progressive: verbIng,
    target,
    detail,
    code,
    command,
    path,
    input,
    rawInput: tool.input,
    output,
    outputPlain,
    content,
    edit,
    time: ms != null ? duration(ms) : '',
    added,
    removed,
  }
}

export function summarizeTools(views: ToolView[]) {
  if (!views.length) return ''
  const groups = new Map<string, string[]>()
  for (const v of views) {
    const key = v.verb
    const arr = groups.get(key) ?? []
    if (v.target && !arr.includes(v.target)) arr.push(v.target)
    groups.set(key, arr)
  }
  const parts: string[] = []
  for (const [verb, targets] of groups) {
    const shown = targets.slice(0, 2).join(', ')
    const more = targets.length > 2 ? ` +${targets.length - 2}` : ''
    parts.push(shown ? `${parts.length ? verb.toLowerCase() : verb} ${shown}${more}` : parts.length ? verb.toLowerCase() : verb)
  }
  const failed = views.filter(v => v.status === 'failed').length
  return parts.join(', ') + (failed ? ` · ${failed} failed` : '')
}
