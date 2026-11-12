// deck-ghost: the /ghost mode for a Claude Code operator. On by default.
//
// With ghost on:
//   - tool-call rows, tool results and folded tool groups draw nothing
//     (ctrl+o still shows everything; the model's context is untouched)
//   - the watcher's own wake-up notifications draw nothing
//   - short mid-turn narration ("Let me check.") draws nothing (hooks/narration.ts)
//   - the live daemons (the DAEMONS row) sit above the hex stream (hooks/hexstream.ts):
//     during a turn the working spinner draws both, and the band above the
//     prompt draws nothing; between turns the band draws the DAEMONS row, and the
//     stream under it while any daemon is working
//   - a dim note is added to the transcript when a daemon reports
//     (a display-only notice: the model never reads it)
//
// /ghost toggles it, stored as ghost=on|off in config/deck.conf (on unless
// it says off). Outside a configured deck home the mod does nothing at all.
// A clone set up before the rename to deck still has config/fixer.conf, with
// the setting under lowkey=, until bin/deck-migrate renames both; that is read
// (and written) instead.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { CrewEntry } from '../types'
import { hexStream } from './hexstream'
import { classifyRestored, isWorkingNote, noteKey } from './narration'

const ghost = atom({ plugin: 'deck-ghost', key: 'ghost' } as const, true)
const frame = atom({ plugin: 'deck-ghost', key: 'frame' } as const, 0)
const crew = atom({ plugin: 'deck-ghost', key: 'crew' } as const, [] as CrewEntry[], { shape: 'crew-1' })
const working = atom({ plugin: 'deck-ghost', key: 'working' } as const, false)

const CONF = 'config/deck.conf'
const LEGACY_CONF = 'config/fixer.conf' // before the rename to deck
const JOBS = 'data/jobs'
const FRAME_MS = 120
const POLL_MS = 3000
const TEAL = '#00f0fa'
const IDLE_TEAL = '#00b4bc' // the stream in the band between turns: a little dimmer
const YELLOW = '#fff405'
const MAGENTA = '#ff3ec8' // anything waiting on the user
const AMBER = '#ffb000'
const GREEN = '#3ddc84'

// The watcher's background command is started with a description containing
// this marker (AGENTS.md section 5), so its completion row can be recognized.
const WATCH_MARK = 'deck-wait'

type $ = EngineInterface

// ------------------------------------------------------------- deck files

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

/** The config file and its text: config/deck.conf, else the legacy config/fixer.conf. */
async function readConf($: $): Promise<{ path: string; text: string } | undefined> {
  for (const path of [CONF, LEGACY_CONF]) {
    const text = await readText($, path)
    if (text !== undefined) return { path, text }
  }
  return undefined
}

/** On unless ghost=off; a config without ghost= falls back to its old name, lowkey=. */
function ghostOn(conf: Record<string, string>): boolean {
  return (conf.ghost ?? conf.lowkey) !== 'off'
}

async function writeGhost($: $, on: boolean): Promise<boolean> {
  const conf = await readConf($)
  if (conf === undefined) return false
  const lines = conf.text.split('\n').filter(l => l !== '' && !l.startsWith('ghost=') && !l.startsWith('lowkey='))
  lines.push(`ghost=${on ? 'on' : 'off'}`)
  try {
    await $.fs.write(conf.path, lines.join('\n') + '\n')
    return true
  } catch {
    return false
  }
}

const ACTIVE = new Set(['starting', 'running', 'blocked', 'review', 'reported', 'failed'])
const RUNNING = new Set(['starting', 'running'])

/** Reads every job; returns live daemons and any status lines not yet seen. */
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

/**
 * Refines the job statuses with Herdr: a running daemon at an approval or
 * question dialog becomes `dialog`, and one whose pane Herdr sees idle or done
 * does not count as working. Without Herdr the job status alone decides.
 */
async function withHerdr(
  $: $,
  live: CrewEntry[],
  panes: Record<string, string>,
): Promise<{ crew: CrewEntry[]; working: boolean }> {
  const byStatus = { crew: live, working: live.some(r => RUNNING.has(r.state)) }
  if (!byStatus.working) return byStatus
  try {
    const { exitCode, stdout } = await $.process.run(['herdr', 'agent', 'list'], { timeoutMs: 5000 })
    if (exitCode !== 0) return byStatus
    const agents = (JSON.parse(stdout)?.result?.agents ?? []) as Array<{ pane_id: string; agent_status: string }>
    const status = new Map(agents.map(a => [panes[a.pane_id], a.agent_status]))
    const next = live.map(r => (r.state === 'running' && status.get(r.id) === 'blocked' ? { ...r, state: 'dialog' } : r))
    const quiet = (s: string | undefined) => s === 'blocked' || s === 'idle' || s === 'done'
    return { crew: next, working: next.some(r => RUNNING.has(r.state) && !quiet(status.get(r.id))) }
  } catch {
    return byStatus
  }
}

const GLYPH: Record<string, string> = {
  done: '⚡',
  blocked: '◆',
  failed: '✖',
}

async function poll($: $): Promise<void> {
  const { live, notes, panes } = await scanJobs($)
  const on = await read($, ghost)
  if (on) {
    for (const note of notes) {
      const event = note.split(': ')[1]?.split(' ')[0] ?? ''
      await $.session
        .append({ message: { type: 'system', content: [{ type: 'text', text: `${GLYPH[event] ?? '▸'} ${note}` }] } })
        .catch(() => undefined)
    }
  }
  const next = on ? await withHerdr($, live, panes) : { crew: live, working: false }
  const before = await read($, crew)
  if (JSON.stringify(before) !== JSON.stringify(next.crew)) await update($, crew, () => next.crew)
  if ((await read($, working)) !== next.working) await update($, working, () => next.working)
}

function hidden($: $, e: Parameters<$['ui']['resolve']>[0]) {
  const { Box } = $.ui.resolve(e)
  return <Box display="none" />
}

type Els = ReturnType<$['ui']['resolve']>

const stateColor = (s: string) =>
  s === 'running' || s === 'starting' ? TEAL : s === 'review' || s === 'reported' ? GREEN : s === 'failed' ? AMBER : MAGENTA
const stateText = (s: string) =>
  s === 'dialog' || s === 'blocked' ? s.toUpperCase() : s === 'review' || s === 'reported' ? 'ready' : s

/** The `▌DAEMONS` row: each live daemon and its state. */
function daemonsRow({ Box, Text }: Els, daemons: CrewEntry[]) {
  return (
    <Box flexDirection="row" flexWrap="wrap">
      <Text color={YELLOW} bold>▌DAEMONS </Text>
      {daemons.map(r => (
        <Text>
          <Text dimColor> ▸ </Text>
          <Text>{r.id} </Text>
          <Text color={stateColor(r.state)}>⟨{stateText(r.state)}⟩</Text>
        </Text>
      ))}
    </Box>
  )
}

/** The two hex-stream rows. */
function streamRows({ Text }: Els, width: number, f: number, teal?: string) {
  return hexStream(width, f, teal).map(segs => (
    <Text>
      {segs.map(s => (
        <Text color={s.color} bold={s.bold} dimColor={s.dim}>
          {s.text}
        </Text>
      ))}
    </Text>
  ))
}

type Anim = { configured: boolean; turnRunning: boolean; timer?: { cancel(): void } }

/** The frame timer runs while ghost is on and a turn is running or a daemon is working. */
async function ensureAnimation($: $, anim: Anim): Promise<void> {
  const want = anim.configured && (await read($, ghost)) && (anim.turnRunning || (await read($, working)))
  if (want && !anim.timer) {
    anim.timer = $.clock.every(FRAME_MS, () => void update($, frame, n => (n + 1) % 1_000_000).catch(() => undefined))
  } else if (!want && anim.timer) {
    anim.timer.cancel()
    anim.timer = undefined
  }
}

// ------------------------------------------------------------------ the mod

export const register: Register = on => {
  const anim: Anim = { configured: false, turnRunning: false }
  let poller: { cancel(): void } | undefined
  // Mid-turn narration seen this session, by noteKey; a text that was ever a reply stays visible.
  const notes = new Set<string>()
  const replies = new Set<string>()

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const file = await readConf($)
    if (file === undefined) return result // not a configured deck home
    anim.configured = true
    const conf = parseConf(file.text)
    await update($, ghost, () => ghostOn(conf))
    await $.command.register({
      name: 'ghost',
      description: 'Go ghost: hide tool-call clutter, show the daemons above the prompt',
    })
    notes.clear()
    replies.clear()
    try {
      const restored = classifyRestored(await $.session.messages())
      for (const k of restored.notes) notes.add(k)
      for (const k of restored.replies) replies.add(k)
    } catch {
      // an unreadable transcript leaves restored narration visible
    }
    poller?.cancel()
    await poll($) // seeds what has been seen, so old events don't replay
    await ensureAnimation($, anim)
    poller = $.clock.every(POLL_MS, () =>
      void poll($)
        .then(() => ensureAnimation($, anim))
        .catch(() => undefined),
    )
    return result
  })

  on('command.run', { command: 'ghost' }, async $ => {
    if (!anim.configured) return { text: 'deck is not set up in this folder yet.' }
    const now = !(await read($, ghost))
    if (!(await writeGhost($, now))) {
      $.ui.toast('Ghost unchanged: could not write the config file')
      return {}
    }
    await update($, ghost, () => now)
    await ensureAnimation($, anim)
    $.ui.toast(now ? 'Ghost on' : 'Ghost off')
    return {}
  })

  on('turn.start', async ($, e, next) => {
    anim.turnRunning = true
    await ensureAnimation($, anim)
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    anim.turnRunning = false
    await ensureAnimation($, anim)
    return next(e)
  })
  on('turn.abort', async ($, e, next) => {
    anim.turnRunning = false
    await ensureAnimation($, anim)
    return next(e)
  })

  // Records which text blocks of each main-agent step are working notes. The
  // stream passes through untouched: only the drawing changes, never the context.
  on('turn.step', async function* ($, e, next) {
    const stream = next(e)
    if (!anim.configured || e.agentId !== undefined) {
      for await (const chunk of stream) yield chunk
      return await stream.result
    }
    const blocks = new Map<number, string>()
    for await (const chunk of stream) {
      if (chunk.kind === 'text') blocks.set(chunk.index, (blocks.get(chunk.index) ?? '') + chunk.text)
      yield chunk
    }
    const result = await stream.result
    let changed = false
    for (const text of [...blocks.values(), result.answer]) {
      const key = noteKey(text)
      if (key === '') continue
      if (isWorkingNote(result, text)) {
        if (replies.has(key) || notes.has(key)) continue
        notes.add(key)
        changed = true
      } else {
        if (!replies.has(key)) {
          replies.add(key)
          changed = true
        }
        if (notes.delete(key)) changed = true
      }
    }
    if (changed && (await read($, ghost))) $.ui.invalidate('ui.render')
    return result
  })

  // During a turn the spinner carries the DAEMONS row above the stream; the band stays empty.
  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (!anim.configured || !(await read($, ghost))) return next(e)
    const els = $.ui.resolve(e)
    const { Box } = els
    const daemons = await read($, crew)
    const width = Math.max(8, (e.viewport?.columns ?? 80) - 4)
    return (
      <Box flexDirection="column" marginTop={1}>
        {daemons.length > 0 ? daemonsRow(els, daemons) : null}
        <Box flexDirection="column" paddingLeft={2}>
          {streamRows(els, width, await read($, frame))}
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!anim.configured || !(await read($, ghost))) return next(e)
    // AssistantMessage has no isExpanded in the 2.1.322 types; honour one if the engine sends it.
    if ((e.props as { isExpanded?: boolean }).isExpanded) return next(e)
    const key = noteKey(e.props.text)
    return key !== '' && notes.has(key) && !replies.has(key) ? hidden($, e) : next(e)
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (!anim.configured || e.props.isExpanded || !(await read($, ghost))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    if (!anim.configured || e.props.isExpanded || !(await read($, ghost))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    if (!anim.configured || e.props.isExpanded || !(await read($, ghost))) return next(e)
    return hidden($, e)
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (!anim.configured || e.props.isExpanded || !(await read($, ghost))) return next(e)
    if (e.props.origin.kind === 'task-notification' && e.props.text.includes(WATCH_MARK)) return hidden($, e)
    return next(e)
  })

  // Between turns the band draws the DAEMONS row, and the stream under it while a daemon works.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!anim.configured || !(await read($, ghost))) return next(e)
    if (e.props.isWorking) return next(e) // the spinner draws the DAEMONS row during a turn
    const daemons = await read($, crew)
    if (daemons.length === 0) return next(e)
    const els = $.ui.resolve(e)
    const { Box } = els
    const animate = !e.props.isCollapsed && (await read($, working))
    return (
      <Box flexDirection="column">
        {daemonsRow(els, daemons)}
        {animate ? streamRows(els, Math.max(8, e.props.bodyColumns), await read($, frame), IDLE_TEAL) : null}
      </Box>
    )
  })
}
