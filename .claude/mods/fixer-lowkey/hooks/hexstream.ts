// The /lowkey working-row animation: two rows of drifting hex and binary,
// with a yellow glitch column sweeping across, in the cyberpunk teal-and-yellow palette. A pure function of the row
// width and a frame counter (one tick every 120ms while a turn runs), so it
// can be tested on its own.

export type Seg = { text: string; color: string; bold?: boolean; dim?: boolean }
export type Row = Seg[]

// Set directly rather than with the dim attribute, which many terminals draw as gray.
const TEAL = '#00f0fa'
const YELLOW = '#fff405'
const HEX = '0123456789ABCDEF'

function hash(n: number): number {
  let x = (n | 0) ^ 0x9e3779b9
  x = Math.imul(x ^ (x >>> 16), 0x85ebca6b)
  x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35)
  return (x ^ (x >>> 16)) >>> 0
}

/** One cell: each column ticks over at its own pace. */
function cell(col: number, r: number, f: number): string {
  const seed = hash(col * 7919 + r * 104729)
  const pace = 3 + (seed % 6)
  const tick = Math.floor((f + (seed % 17)) / pace)
  const v = hash(seed ^ tick)
  if (v % 7 < 2) return ' '
  return v % 3 === 0 ? (v % 2 ? '1' : '0') : HEX.charAt(v % 16)
}

export function hexStream(width: number, f: number): Row[] {
  const g = (Math.floor(f * 1.5) % (width + 16)) - 8 // glitch column; off-screen part of the time
  return [0, 1].map(r => {
    const out: Row = []
    for (let c = 0; c < width; c++) {
      let s: Seg
      if (c === g) s = { text: '▌', color: YELLOW, bold: true }
      else if (c === g + 1) {
        const ch = cell(c, r, f * 3)
        s = { text: ch === ' ' ? HEX.charAt(hash(f + r) % 16) : ch, color: YELLOW, bold: true }
      } else s = { text: cell(c, r, f), color: TEAL }
      const last = out[out.length - 1]
      if (last && last.color === s.color && last.bold === s.bold && last.dim === s.dim) last.text += s.text
      else out.push(s)
    }
    return out
  })
}
