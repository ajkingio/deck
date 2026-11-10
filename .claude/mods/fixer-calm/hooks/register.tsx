// fixer-calm: the /calm mode for a Claude Code Fixer.
//
// With calm on:
//   - tool-call rows, tool results and folded tool groups draw nothing
//     (ctrl+o still shows everything; the model's context is untouched)
//   - the watcher's own wake-up notifications draw nothing
//   - the working spinner becomes the active theme's animation
//     (theme frontmatter `calm: hex-stream`; anything else keeps the stock spinner)
//   - a crew band above the prompt lists live runners
//   - a dim note is added to the transcript when a runner reports
//     (a display-only notice: the model never reads it)
//
// The choice is stored as calm=on|off in config/fixer.conf. Outside a
// configured fixer home the mod does nothing at all.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { CrewEntry } from '../types'

const calm = atom({ plugin: 'fixer-calm', key: 'calm' } as const, false)
const sprite = atom({ plugin: 'fixer-calm', key: 'sprite' } as const, 'none')
const frame = atom({ plugin: 'fixer-calm', key: 'frame' } as const, 0)
const crew = atom({ plugin: 'fixer-calm', key: 'crew' } as const, [] as CrewEntry[], { shape: 'crew-1' })

const CONF = 'config/fixer.conf'
const JOBS = 'data/jobs'
const FRAME_MS = 120
const POLL_MS = 3000
const CYAN = '#2bd9ff'
const MAGENTA = '#ff3ec8'
const AMBER = '#ffb000'
const GREEN = '#3ddc84'

// The watcher's background command is started with a description containing
// this marker (AGENTS.md section 5), so its completion row can be recognized.
const WATCH_MARK = 'fixer-wait'

type $ = EngineInterface

// ---------------------------------------------------------------- the sprite

function hash(n: number): number {
  let x = (n | 0) ^ 0x9e3779b9
  x = Math.imul(x ^ (x >>> 16), 0x85ebca6b)
  x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35)
  return (x ^ (x >>> 16)) >>> 0
}

const HEX = '0123456789ABCDEF'

/** One cell of the hex stream: each column ticks over at its own pace. */
function cell(col: number, row: number, f: number): string {
  const seed = hash(col * 7919 + row * 104729)
  const pace = 3 + (seed % 6)
  const tick = Math.floor((f + (seed % 17)) / pace)
  const v = hash(seed ^ tick)
  if (v % 7 < 2) return ' '
  return v % 3 === 0 ? (v % 2 ? '1' : '0') : HEX.charAt(v % 16)
}

/**
 * Two rows of drifting hex and binary, with a glitch column that sweeps left
 * to right. Returns each row as the text before the glitch, the glitch cells,
 * and the text after.
 */
export function hexStream(width: number, f: number): Array<[string, string, string]> {
  const w = Math.max(8, width)
  const sweep = w + 16
  const g = Math.floor(f * 1.5) % sweep - 8 // glitch column; off-screen part of the time
  const rows: Array<[string, string, string]> = []
  for (let r = 0; r < 2; r++) {
    let before = ''
    let glitch = ''
    let after = ''
    for (let c = 0; c < w; c++) {
      if (c === g) glitch += '▌'
      else if (c === g + 1) glitch += cell(c, r, f * 3) === ' ' ? HEX.charAt(hash(f + r) % 16) : cell(c, r, f * 3)
      else if (c < g) before += cell(c, r, f)
      else after += cell(c, r, f)
    }
    rows.push([before, glitch, after])
  }
  return rows
}

// ------------------------------------------------------------- fixer files

function parseConf(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of text.split('\n')) {
    const i = line.indexOf('=')
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim()
  }
  return out
}

async function readText($: $, path: string): Promise<string | undefined> {
  try {
    return (await $.fs.read(path)) as string
  } catch {
    return undefined
  }
}

async function themeSprite($: $, theme: string | undefined): Promise<string> {
  if (!theme) return 'none'
  const text = await readText($, `themes/${theme}.md`)
  const m = text?.match(/^---\n[\s\S]*?^calm:\s*(\S+)\s*$[\s\S]*?^---$/m)
  return m?.[1] ?? 'none'
}

async function writeCalm($: $, on: boolean): Promise<boolean> {
  const text = await readText($, CONF)
  if (text === undefined) return false
  const lines = text.split('\n').filter(l => !l.startsWith('calm=') && l !== '')
  lines.push(`calm=${on ? 'on' : 'off'}`)
  try {
    await $.fs.write(CONF, lines.join('\n') + '\n')
    return true
  } catch {
    return false
  }
}

const ACTIVE = new Set(['starting', 'running', 'blocked', 'review', 'reported', 'failed'])

/** Reads every job; returns live runners and any status lines not yet seen. */
async function scanJobs($: $): Promise<{ live: CrewEntry[]; notes: string[]; panes: Record<string, string> }> {
  const live: CrewEntry[] = []
  const notes: string[] = []
  const panes: Record<string, string> = {}
  let entries: Awaited<ReturnType<$['fs']['list']>> = []
  try {
    entries = await $.fs.list(JOBS)
  } catch {
    return { live, notes, panes }
  }
  for (const entry of entries) {
    const id = entry.name
    const conf = await readText($, `${JOBS}/${id}/job.conf`)
    if (conf === undefined) continue
    const job = parseConf(conf)
    const log = (await readText($, `${JOBS}/${id}/status.log`)) ?? ''
    const lines = log.split('\n').filter(l => l.trim() !== '')
    const seenKey = `seen:${id}`
    const seen = Number((await $.store.get(seenKey)) ?? -1)
    if (seen >= 0 && lines.length > seen) {
      for (const line of lines.slice(seen)) {
        const [, event = '', ...rest] = line.split(' ')
        notes.push(`${id}: ${event}${rest.length ? ' · ' + rest.join(' ') : ''}`)
      }
    }
    if (seen !== lines.length) await $.store.set(seenKey, lines.length)
    if (ACTIVE.has(job.status ?? '')) {
      live.push({ id, state: job.status ?? 'unknown' })
      if (job.pane) panes[job.pane] = id
    }
  }
  return { live, notes, panes }
}

/** Marks runners Herdr sees waiting at an approval or question dialog. */
async function withHerdr($: $, live: CrewEntry[], panes: Record<string, string>): Promise<CrewEntry[]> {
  if (!live.some(r => r.state === 'running')) return live
  try {
    const { exitCode, stdout } = await $.process.run(['herdr', 'agent', 'list'], { timeoutMs: 5000 })
    if (exitCode !== 0) return live
    const agents = (JSON.parse(stdout)?.result?.agents ?? []) as Array<{ pane_id: string; agent_status: string }>
    const blocked = new Set(agents.filter(a => a.agent_status === 'blocked').map(a => panes[a.pane_id]))
    return live.map(r => (r.state === 'running' && blocked.has(r.id) ? { ...r, state: 'dialog' } : r))
  } catch {
    return live
  }
}

const GLYPH: Record<string, string> = {
  done: '⚡',
  blocked: '◆',
  failed: '✖',
}

async function poll($: $): Promise<void> {
  const { live, notes, panes } = await scanJobs($)
  const isCalm = await read($, calm)
  if (isCalm) {
    for (const note of notes) {
      const event = note.split(': ')[1]?.split(' ')[0] ?? ''
      await $.session
        .append({ message: { type: 'system', content: [{ type: 'text', text: `${GLYPH[event] ?? '▸'} ${note}` }] } })
        .catch(() => undefined)
    }
  }
  const next = isCalm ? await withHerdr($, live, panes) : live
  const before = await read($, crew)
  if (JSON.stringify(before) !== JSON.stringify(next)) await update($, crew, () => next)
}

function hidden($: $, e: Parameters<$['ui']['resolve']>[0]) {
  const { Box } = $.ui.resolve(e)
  return <Box display="none" />
}

// ------------------------------------------------------------------ the mod

export const register: Register = on => {
  let configured = false
  let animation: { cancel(): void } | undefined
  let poller: { cancel(): void } | undefined

  const stopAnimation = () => {
    animation?.cancel()
    animation = undefined
  }

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const text = await readText($, CONF)
    if (text === undefined) return result // not a configured fixer home
    configured = true
    const conf = parseConf(text)
    await update($, calm, () => conf.calm === 'on')
    const spriteName = await themeSprite($, conf.theme)
    await update($, sprite, () => spriteName)
    await $.command.register({
      name: 'calm',
      description: 'Toggle calm mode: hide tool-call clutter, show the crew band and runner notes',
    })
    poller?.cancel()
    await poll($) // seeds what has been seen, so old events don't replay
    poller = $.clock.every(POLL_MS, () => void poll($).catch(() => undefined))
    return result
  })

  on('command.run', { command: 'calm' }, async $ => {
    if (!configured) return { text: 'fixer is not set up in this folder yet.' }
    const now = !(await read($, calm))
    if (!(await writeCalm($, now))) {
      $.ui.toast('Calm unchanged: could not write config/fixer.conf')
      return {}
    }
    await update($, calm, () => now)
    if (!now) stopAnimation()
    const conf = parseConf((await readText($, CONF)) ?? '')
    const spriteName = await themeSprite($, conf.theme)
    await update($, sprite, () => spriteName)
    $.ui.toast(now ? 'Calm on' : 'Calm off')
    return {}
  })

  // The animation runs only while a turn does.
  on('turn.start', async ($, e, next) => {
    stopAnimation()
    if (configured && (await read($, calm)) && (await read($, sprite)) !== 'none') {
      animation = $.clock.every(FRAME_MS, () => void update($, frame, n => (n + 1) % 1_000_000).catch(() => undefined))
    }
    return next(e)
  })
  on('turn.complete', ($, e, next) => {
    stopAnimation()
    return next(e)
  })
  on('turn.abort', ($, e, next) => {
    stopAnimation()
    return next(e)
  })

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (!configured || !(await read($, calm)) || (await read($, sprite)) !== 'hex-stream') return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const width = (e.viewport?.columns ?? 80) - 4
    const rows = hexStream(width, await read($, frame))
    return (
      <Box flexDirection="column" paddingLeft={2} marginTop={1}>
        {rows.map(([before, glitch, after]) => (
          <Text>
            <Text color={CYAN} dimColor>{before}</Text>
            <Text color={MAGENTA} bold>{glitch}</Text>
            <Text color={CYAN} dimColor>{after}</Text>
          </Text>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, calm))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, calm))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, calm))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, calm))) return next(e)
    if (e.props.origin.kind === 'task-notification' && e.props.text.includes(WATCH_MARK)) return hidden($, e)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!configured || !(await read($, calm))) return next(e)
    const runners = await read($, crew)
    if (runners.length === 0) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const color = (s: string) =>
      s === 'running' || s === 'starting' ? CYAN : s === 'review' || s === 'reported' ? GREEN : s === 'failed' ? AMBER : MAGENTA
    const label = (s: string) =>
      s === 'dialog' || s === 'blocked' ? s.toUpperCase() : s === 'review' || s === 'reported' ? 'ready' : s
    return (
      <Box flexDirection="row" flexWrap="wrap">
        <Text color={MAGENTA} bold>▌RUNNERS </Text>
        {runners.map(r => (
          <Text>
            <Text dimColor> ▸ </Text>
            <Text>{r.id} </Text>
            <Text color={color(r.state)}>⟨{label(r.state)}⟩</Text>
          </Text>
        ))}
      </Box>
    )
  })
}
