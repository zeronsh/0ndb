export interface TextSplice {
  at: number
  del: number
  text: string
}

const enc = new TextEncoder()
const dec = new TextDecoder()

export function applyUtf8Splices(content: string, splices: TextSplice[]): string {
  if (!splices.length) return content
  const src = enc.encode(content)
  const parts = splices.map(s => ({
    at: Math.max(0, Math.min(s.at, src.length)),
    del: Math.max(0, s.del),
    bytes: s.text ? enc.encode(s.text) : new Uint8Array(0),
  }))
  parts.sort((a, b) => a.at - b.at)

  let outLen = src.length
  for (const p of parts) {
    const clampedDel = Math.min(p.del, src.length - p.at)
    outLen += p.bytes.length - clampedDel
  }
  const out = new Uint8Array(Math.max(0, outLen))
  let srcPos = 0
  let dstPos = 0
  for (const p of parts) {
    const at = Math.max(srcPos, p.at)
    if (at > srcPos) {
      out.set(src.subarray(srcPos, at), dstPos)
      dstPos += at - srcPos
    }
    if (p.bytes.length) {
      out.set(p.bytes, dstPos)
      dstPos += p.bytes.length
    }
    srcPos = Math.min(src.length, at + p.del)
  }
  if (srcPos < src.length) {
    out.set(src.subarray(srcPos), dstPos)
    dstPos += src.length - srcPos
  }
  return dec.decode(dstPos === out.length ? out : out.subarray(0, dstPos))
}

export function utf16ToUtf8Offset(text: string, utf16Offset: number): number {
  const limit = Math.max(0, Math.min(utf16Offset, text.length))
  let bytes = 0
  for (let i = 0; i < limit; i++) {
    const code = text.charCodeAt(i)
    if (code < 0x80) {
      bytes += 1
    } else if (code < 0x800) {
      bytes += 2
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1)
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4
        i += 1
      } else {
        bytes += 3
      }
    } else {
      bytes += 3
    }
  }
  return bytes
}

export function utf8ToUtf16Offset(text: string, utf8Offset: number): number {
  if (utf8Offset <= 0) return 0
  let bytes = 0
  let i = 0
  while (i < text.length && bytes < utf8Offset) {
    const code = text.charCodeAt(i)
    let w = 3
    let step = 1
    if (code < 0x80) {
      w = 1
    } else if (code < 0x800) {
      w = 2
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1)
      if (next >= 0xdc00 && next <= 0xdfff) {
        w = 4
        step = 2
      }
    }
    if (bytes + w > utf8Offset) break
    bytes += w
    i += step
  }
  return i
}

export function changedLinesFromSplices(afterContent: string, splices: TextSplice[]): number[] {
  if (!splices.length) return []
  const sorted = [...splices].sort((a, b) => a.at - b.at)
  const ranges: [number, number][] = []
  let shift = 0
  for (const s of sorted) {
    const insLen = s.text ? enc.encode(s.text).length : 0
    const start = Math.max(0, s.at + shift)
    const end = insLen > 0 ? start + insLen - 1 : start
    ranges.push([start, end])
    shift += insLen - s.del
  }
  const bytes = enc.encode(afterContent)
  const lines = new Set<number>()
  let line = 0
  let rIdx = 0
  let lineStart = 0
  for (let i = 0; i <= bytes.length && rIdx < ranges.length; i++) {
    const isEnd = i === bytes.length || bytes[i] === 0x0a
    if (!isEnd) continue
    const lineEnd = i
    while (rIdx < ranges.length && ranges[rIdx][1] < lineStart) rIdx++
    let k = rIdx
    while (k < ranges.length && ranges[k][0] <= lineEnd) {
      lines.add(line)
      k++
    }
    lineStart = i + 1
    line++
  }
  return [...lines].sort((a, b) => a - b)
}

export interface SpliceOp {
  at: number
  del: number
  ins: number
}

export function computeUtf8Splices(before: string, after: string): { splices: SpliceOp[]; inserted: string } {
  if (before === after) return { splices: [], inserted: '' }
  const a = enc.encode(before)
  const b = enc.encode(after)
  let prefix = 0
  const minLen = Math.min(a.length, b.length)
  while (prefix < minLen && a[prefix] === b[prefix]) prefix++
  while (prefix > 0 && ((prefix < a.length && (a[prefix] & 0xc0) === 0x80) || (prefix < b.length && (b[prefix] & 0xc0) === 0x80))) {
    prefix--
  }
  let suffix = 0
  const maxSuffix = minLen - prefix
  while (suffix < maxSuffix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix++
  while (
    suffix > 0 &&
    ((a[a.length - suffix] & 0xc0) === 0x80 || (b[b.length - suffix] & 0xc0) === 0x80)
  ) {
    suffix--
  }
  const del = a.length - prefix - suffix
  const insBytes = b.subarray(prefix, b.length - suffix)
  return {
    splices: [{ at: prefix, del, ins: insBytes.length }],
    inserted: dec.decode(insBytes),
  }
}

