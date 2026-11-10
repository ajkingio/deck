// Quiet-mode animations for the working row. Each one is a pure function of
// the row width and a frame counter (one tick every 120ms while a turn runs),
// returning rows of colored segments. No engine access here, so every
// animation can be tested on its own.

export type Seg = { text: string; color: string; bold?: boolean; dim?: boolean }
export type Row = Seg[]
export type Animation = (width: number, frame: number, words: readonly string[]) => Row[]

const CYAN = '#2bd9ff'
const MAGENTA = '#ff3ec8'
const BLUE = '#4fa3ff'
const FOAM = '#cfe8ff'
const GRAY = '#7a7a7a'
const ACCENT = '#d77757'

export function hash(n: number): number {
  let x = (n | 0) ^ 0x9e3779b9
  x = Math.imul(x ^ (x >>> 16), 0x85ebca6b)
  x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35)
  return (x ^ (x >>> 16)) >>> 0
}

/** Builds a row cell by cell, merging neighbors that share a style. */
function row(width: number, at: (col: number) => Seg): Row {
  const out: Row = []
  for (let c = 0; c < width; c++) {
    const s = at(c)
    const last = out[out.length - 1]
    if (last && last.color === s.color && last.bold === s.bold && last.dim === s.dim) last.text += s.text
    else out.push({ ...s })
  }
  return out
}

/** Pads or cuts a one-row line to exactly `width` cells. */
function fit(segs: Row, width: number): Row {
  const out: Row = []
  let used = 0
  for (const s of segs) {
    if (used >= width) break
    const text = s.text.slice(0, width - used)
    out.push({ ...s, text })
    used += text.length
  }
  if (used < width) out.push({ text: ' '.repeat(width - used), color: GRAY })
  return out
}

// ---------------------------------------------------------------- hex-stream
// Two rows of drifting hex and binary; a magenta glitch column sweeps across.

const HEX = '0123456789ABCDEF'

function hexCell(col: number, r: number, f: number): string {
  const seed = hash(col * 7919 + r * 104729)
  const pace = 3 + (seed % 6)
  const tick = Math.floor((f + (seed % 17)) / pace)
  const v = hash(seed ^ tick)
  if (v % 7 < 2) return ' '
  return v % 3 === 0 ? (v % 2 ? '1' : '0') : HEX.charAt(v % 16)
}

export const hexStream: Animation = (width, f) => {
  const g = (Math.floor(f * 1.5) % (width + 16)) - 8
  return [0, 1].map(r =>
    row(width, c => {
      if (c === g) return { text: '▌', color: MAGENTA, bold: true }
      if (c === g + 1) {
        const ch = hexCell(c, r, f * 3)
        return { text: ch === ' ' ? HEX.charAt(hash(f + r) % 16) : ch, color: MAGENTA, bold: true }
      }
      return { text: hexCell(c, r, f), color: CYAN, dim: true }
    }),
  )
}

// ---------------------------------------------------------------- ice-breach
// A daemon rides a data line left to right; the ICE wall ahead of it decays
// █ → ▓ → ▒ → ░ as it hits, and the wall regrows behind it for the next pass.

export const iceBreach: Animation = (width, f) => {
  const span = width + 6
  const x = Math.floor(f / 2) % span - 2 // runner column; enters and leaves off-screen
  const top = row(width, c => {
    const d = c - x
    if (d < -1) return hash(c * 31 + Math.floor(f / 4)) % 9 === 0 ? { text: '·', color: CYAN, dim: true } : { text: ' ', color: CYAN }
    if (d === -1 || d === 0) return { text: '░', color: MAGENTA }
    if (d === 1) return { text: '▒', color: MAGENTA, bold: true }
    if (d === 2) return { text: '▓', color: CYAN, bold: true }
    return { text: '█', color: CYAN, dim: true }
  })
  const bottom = row(width, c => {
    if (c === x) return { text: '◢', color: MAGENTA, bold: true }
    if (c === x + 1) return { text: '▶', color: MAGENTA, bold: true }
    return c < x ? { text: '═', color: CYAN, dim: true } : { text: '─', color: CYAN, dim: true }
  })
  return [top, bottom]
}

// -------------------------------------------------------------------- glitch
// One row cycling the theme's verbs; each new verb arrives scrambled and
// resolves character by character.

const SCRAMBLE = '!@#$%&*?/\\|<>01'
export const DEFAULT_WORDS = ['slicing ICE', 'tracing route', 'spoofing ident', 'decrypting', 'compiling daemon', 'rerouting']

export const glitch: Animation = (width, f, words) => {
  const list = words.length > 0 ? words : DEFAULT_WORDS
  const hold = 24 // frames per verb (~3s)
  const word = list[Math.floor(f / hold) % list.length] ?? ''
  const age = f % hold
  const settled = Math.min(word.length, age * 2) // two characters resolve per frame
  let text = ''
  for (let i = 0; i < word.length; i++) {
    const ch = word.charAt(i)
    text += i < settled || ch === ' ' ? ch : SCRAMBLE.charAt(hash(f * 13 + i) % SCRAMBLE.length)
  }
  const dots = '.'.repeat(1 + (Math.floor(f / 4) % 3))
  return [
    fit(
      [
        { text: '◢ ', color: MAGENTA, bold: true },
        { text, color: settled < word.length ? MAGENTA : CYAN, bold: settled < word.length },
        { text: dots, color: CYAN, dim: true },
      ],
      width,
    ),
  ]
}

// ---------------------------------------------------------------------- tide
// Two rows of rolling swell: a long wave with a shorter one riding on it.

const BARS = ' ▁▂▃▄▅▆▇█'

export const tide: Animation = (width, f) => {
  const t = f / 3
  const height = (c: number) => {
    const h = Math.sin((c + t) / 6) * 0.6 + Math.sin((c - t * 0.7) / 2.7) * 0.4 // -1..1
    return Math.round(((h + 1) / 2) * 15) // 0..15 eighths across two rows
  }
  const top = row(width, c => {
    const h = height(c) - 8
    return h > 0 ? { text: BARS.charAt(h), color: FOAM, dim: true } : { text: ' ', color: FOAM }
  })
  const bottom = row(width, c => {
    const h = Math.min(8, height(c))
    return { text: BARS.charAt(Math.max(1, h)), color: BLUE }
  })
  return [top, bottom]
}

// --------------------------------------------------------------------- pulse
// A bright bar sweeping back and forth along a dotted line.

export const pulse: Animation = (width, f) => {
  const len = 6
  const travel = Math.max(1, width - len)
  const p = f % (travel * 2)
  const x = p < travel ? p : travel * 2 - p
  return [
    row(width, c => {
      if (c >= x && c < x + len) return { text: '━', color: ACCENT, bold: c === x + 2 || c === x + 3 }
      return { text: c % 2 ? '·' : ' ', color: GRAY, dim: true }
    }),
  ]
}

export const ANIMATIONS: Record<string, Animation> = {
  'hex-stream': hexStream,
  'ice-breach': iceBreach,
  glitch,
  tide,
  pulse,
}

/** Every name /calm accepts as an animation, `stock` being Claude's own spinner. */
export const ANIMATION_NAMES = [...Object.keys(ANIMATIONS), 'stock']
