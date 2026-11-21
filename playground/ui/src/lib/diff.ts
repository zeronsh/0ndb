export type DiffLine = { kind: 'ctx' | 'add' | 'del'; text: string; a?: number; b?: number }
export type Hunk = { header: string; lines: DiffLine[] }

export function lineDiff(before: string, after: string): DiffLine[] {
  const a = before === '' ? [] : before.replace(/\n$/, '').split('\n')
  const b = after === '' ? [] : after.replace(/\n$/, '').split('\n')
  let start = 0
  while (start < a.length && start < b.length && a[start] === b[start]) start++
  let endA = a.length
  let endB = b.length
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--
    endB--
  }
  const midA = a.slice(start, endA)
  const midB = b.slice(start, endB)
  const out: DiffLine[] = []
  for (let i = 0; i < start; i++) out.push({ kind: 'ctx', text: a[i], a: i + 1, b: i + 1 })
  if (midA.length * midB.length > 4_000_000) {
    midA.forEach((t, i) => out.push({ kind: 'del', text: t, a: start + i + 1 }))
    midB.forEach((t, i) => out.push({ kind: 'add', text: t, b: start + i + 1 }))
  } else {
    const n = midA.length
    const m = midB.length
    const dp: Uint32Array[] = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1))
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = midA[i] === midB[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1])
    let i = 0
    let j = 0
    while (i < n || j < m) {
      if (i < n && j < m && midA[i] === midB[j]) {
        out.push({ kind: 'ctx', text: midA[i], a: start + i + 1, b: start + j + 1 })
        i++
        j++
      } else if (j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) {
        out.push({ kind: 'add', text: midB[j], b: start + j + 1 })
        j++
      } else {
        out.push({ kind: 'del', text: midA[i], a: start + i + 1 })
        i++
      }
    }
  }
  for (let i = endA, j = endB; i < a.length; i++, j++) out.push({ kind: 'ctx', text: a[i], a: i + 1, b: j + 1 })
  return out
}

export function hunks(lines: DiffLine[], context = 3): Hunk[] {
  const changed = lines.map((l, i) => (l.kind === 'ctx' ? -1 : i)).filter(i => i >= 0)
  if (!changed.length) return []
  const ranges: [number, number][] = []
  for (const i of changed) {
    const lo = Math.max(0, i - context)
    const hi = Math.min(lines.length - 1, i + context)
    const last = ranges.at(-1)
    if (last && lo <= last[1] + 1) last[1] = Math.max(last[1], hi)
    else ranges.push([lo, hi])
  }
  return ranges.map(([lo, hi]) => {
    const slice = lines.slice(lo, hi + 1)
    const firstA = slice.find(l => l.a != null)?.a ?? 0
    const firstB = slice.find(l => l.b != null)?.b ?? 0
    const countA = slice.filter(l => l.kind !== 'add').length
    const countB = slice.filter(l => l.kind !== 'del').length
    return { header: `@@ -${firstA},${countA} +${firstB},${countB} @@`, lines: slice }
  })
}

export function diffStat(lines: DiffLine[]) {
  let added = 0
  let removed = 0
  for (const l of lines) {
    if (l.kind === 'add') added++
    else if (l.kind === 'del') removed++
  }
  return { added, removed }
}
