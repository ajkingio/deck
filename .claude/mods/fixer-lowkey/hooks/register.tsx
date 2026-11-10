// fixer-lowkey: the /lowkey mode for a Claude Code Fixer. On by default.
//
// With lowkey on:
//   - tool-call rows, tool results and folded tool groups draw nothing
//     (ctrl+o still shows everything; the model's context is untouched)
//   - the watcher's own wake-up notifications draw nothing
//   - the working spinner becomes the hex stream (hooks/hexstream.ts)
//   - a band above the prompt lists live mercs
//   - a dim note is added to the transcript when a merc reports
//     (a display-only notice: the model never reads it)
//
// /lowkey toggles it, stored as lowkey=on|off in config/fixer.conf (on unless
// it says off). Outside a configured fixer home the mod does nothing at all.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { CrewEntry } from '../types'
import { hexStream } from './hexstream'

const lowkey = atom({ plugin: 'fixer-lowkey', key: 'lowkey' } as const, true)
const frame = atom({ plugin: 'fixer-lowkey', key: 'frame' } as const, 0)
const crew = atom({ plugin: 'fixer-lowkey', key: 'crew' } as const, [] as CrewEntry[], { shape: 'crew-1' })

const CONF = 'config/fixer.conf'
const JOBS = 'data/jobs'
const FRAME_MS = 120
const POLL_MS = 3000
const TEAL = '#00f0fa'
const YELLOW = '#fff405'
const MAGENTA = '#ff3ec8' // anything waiting on the client
const AMBER = '#ffb000'
const GREEN = '#3ddc84'

// The watcher's background command is started with a description containing
// this marker (AGENTS.md section 5), so its completion row can be recognized.
const WATCH_MARK = 'fixer-wait'

type $ = EngineInterface

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

async function writeLowkey($: $, on: boolean): Promise<boolean> {
  const text = await readText($, CONF)
  if (text === undefined) return false
  const lines = text.split('\n').filter(l => l !== '' && !l.startsWith('lowkey='))
  lines.push(`lowkey=${on ? 'on' : 'off'}`)
  try {
    await $.fs.write(CONF, lines.join('\n') + '\n')
    return true
  } catch {
    return false
  }
}

const ACTIVE = new Set(['starting', 'running', 'blocked', 'review', 'reported', 'failed'])

/** Reads every job; returns live mercs and any status lines not yet seen. */
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

/** Marks mercs Herdr sees waiting at an approval or question dialog. */
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
  const on = await read($, lowkey)
  if (on) {
    for (const note of notes) {
      const event = note.split(': ')[1]?.split(' ')[0] ?? ''
      await $.session
        .append({ message: { type: 'system', content: [{ type: 'text', text: `${GLYPH[event] ?? '▸'} ${note}` }] } })
        .catch(() => undefined)
    }
  }
  const next = on ? await withHerdr($, live, panes) : live
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
    await update($, lowkey, () => conf.lowkey !== 'off')
    await $.command.register({
      name: 'lowkey',
      description: 'Keep it lowkey: hide tool-call clutter, show the mercs above the prompt',
    })
    poller?.cancel()
    await poll($) // seeds what has been seen, so old events don't replay
    poller = $.clock.every(POLL_MS, () => void poll($).catch(() => undefined))
    return result
  })

  on('command.run', { command: 'lowkey' }, async $ => {
    if (!configured) return { text: 'fixer is not set up in this folder yet.' }
    const now = !(await read($, lowkey))
    if (!(await writeLowkey($, now))) {
      $.ui.toast('Lowkey unchanged: could not write config/fixer.conf')
      return {}
    }
    await update($, lowkey, () => now)
    if (!now) stopAnimation()
    $.ui.toast(now ? 'Lowkey on' : 'Lowkey off')
    return {}
  })

  // The animation runs only while a turn does.
  on('turn.start', async ($, e, next) => {
    stopAnimation()
    if (configured && (await read($, lowkey))) {
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
    if (!configured || !(await read($, lowkey))) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const width = Math.max(8, (e.viewport?.columns ?? 80) - 4)
    const rows = hexStream(width, await read($, frame))
    return (
      <Box flexDirection="column" paddingLeft={2} marginTop={1}>
        {rows.map(segs => (
          <Text>
            {segs.map(s => (
              <Text color={s.color} bold={s.bold} dimColor={s.dim}>
                {s.text}
              </Text>
            ))}
          </Text>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, lowkey))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, lowkey))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, lowkey))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (!configured || e.props.isExpanded || !(await read($, lowkey))) return next(e)
    if (e.props.origin.kind === 'task-notification' && e.props.text.includes(WATCH_MARK)) return hidden($, e)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!configured || !(await read($, lowkey))) return next(e)
    const mercs = await read($, crew)
    if (mercs.length === 0) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const color = (s: string) =>
      s === 'running' || s === 'starting' ? TEAL : s === 'review' || s === 'reported' ? GREEN : s === 'failed' ? AMBER : MAGENTA
    const stateText = (s: string) =>
      s === 'dialog' || s === 'blocked' ? s.toUpperCase() : s === 'review' || s === 'reported' ? 'ready' : s
    return (
      <Box flexDirection="row" flexWrap="wrap">
        <Text color={YELLOW} bold>▌MERCS </Text>
        {mercs.map(r => (
          <Text>
            <Text dimColor> ▸ </Text>
            <Text>{r.id} </Text>
            <Text color={color(r.state)}>⟨{stateText(r.state)}⟩</Text>
          </Text>
        ))}
      </Box>
    )
  })
}
