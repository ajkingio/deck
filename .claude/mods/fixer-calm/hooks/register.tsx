// fixer-calm: the /calm mode for a Claude Code Fixer.
//
// With calm on:
//   - tool-call rows, tool results and folded tool groups draw nothing
//     (ctrl+o still shows everything; the model's context is untouched)
//   - the watcher's own wake-up notifications draw nothing
//   - the working spinner becomes an animation (hooks/animations.ts): the
//     theme's `calm:` default, or the client's pick (`/calm <animation>`,
//     stored as calm_animation=), `stock` keeping Claude's own spinner
//   - a crew band above the prompt lists live runners
//   - a dim note is added to the transcript when a runner reports
//     (a display-only notice: the model never reads it)
//
// The choice is stored as calm=on|off in config/fixer.conf, on unless it says
// off. Outside a configured fixer home the mod does nothing at all.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { CrewEntry } from '../types'
import { ANIMATIONS, ANIMATION_NAMES } from './animations'

const calm = atom({ plugin: 'fixer-calm', key: 'calm' } as const, false)
const sprite = atom({ plugin: 'fixer-calm', key: 'sprite' } as const, 'stock')
const words = atom({ plugin: 'fixer-calm', key: 'words' } as const, [] as string[], { shape: 'words-1' })
const frame = atom({ plugin: 'fixer-calm', key: 'frame' } as const, 0)
const crew = atom({ plugin: 'fixer-calm', key: 'crew' } as const, [] as CrewEntry[], { shape: 'crew-1' })
const label = atom({ plugin: 'fixer-calm', key: 'label' } as const, 'CREW')
const command = atom({ plugin: 'fixer-calm', key: 'command' } as const, 'calm')

// The toggle is /calm in every theme, plus the theme's own name for it
// (`calm_command:` in its frontmatter: ghost, lowkey, focus). Commands can't be
// unregistered, so a name from an earlier theme stays usable but is hidden.
const registered = new Set<string>()
const DESCRIPTION = 'Quiet mode: hide tool-call clutter, show the crew band and worker notes. Add an animation name to switch it, or "list"'
const HINT = '[animation | list]'

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

async function themeField($: $, theme: string | undefined, key: string): Promise<string | undefined> {
  if (!theme) return undefined
  const text = await readText($, `themes/${theme}.md`)
  const head = text?.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? ''
  for (const line of head.split('\n')) {
    const i = line.indexOf(':')
    if (i > 0 && line.slice(0, i).trim() === key) return line.slice(i + 1).trim() || undefined
  }
  return undefined
}

async function ensureCommand($: $, name: string): Promise<void> {
  if (registered.has(name) || !/^[a-z][a-z0-9-]{0,31}$/.test(name)) return
  await $.command.register({ name, description: DESCRIPTION, argumentHint: HINT })
  registered.add(name)
}

/** Reads the animation (client's pick, else the theme's), its words, the crew-band label and command name into state. */
async function loadTheme($: $): Promise<void> {
  const conf = parseConf((await readText($, CONF)) ?? '')
  const picked = conf.calm_animation || (await themeField($, conf.theme, 'calm')) || 'stock'
  const spriteName = ANIMATION_NAMES.includes(picked) ? picked : 'stock'
  const wordList = ((await themeField($, conf.theme, 'calm_words')) ?? '')
    .split(',')
    .map(w => w.trim())
    .filter(w => w !== '')
  if (JSON.stringify(await read($, words)) !== JSON.stringify(wordList)) await update($, words, () => wordList)
  const labelText = ((await themeField($, conf.theme, 'crew_label')) ?? 'CREW').toUpperCase()
  const name = (await themeField($, conf.theme, 'calm_command')) ?? 'calm'
  if ((await read($, sprite)) !== spriteName) await update($, sprite, () => spriteName)
  if ((await read($, label)) !== labelText) await update($, label, () => labelText)
  await ensureCommand($, 'calm')
  await ensureCommand($, name)
  if ((await read($, command)) !== name) {
    await update($, command, () => name)
    $.ui.invalidate('command.describe')
  }
}

async function writeConf($: $, values: Record<string, string>): Promise<boolean> {
  const text = await readText($, CONF)
  if (text === undefined) return false
  const keys = Object.keys(values)
  const lines = text.split('\n').filter(l => l !== '' && !keys.some(k => l.startsWith(`${k}=`)))
  for (const k of keys) lines.push(`${k}=${values[k]}`)
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
  await loadTheme($) // picks up a /retheme without a restart
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
    await update($, calm, () => conf.calm !== 'off')
    await loadTheme($) // also registers /calm and the theme's name for it
    poller?.cancel()
    await poll($) // seeds what has been seen, so old events don't replay
    poller = $.clock.every(POLL_MS, () => void poll($).catch(() => undefined))
    return result
  })

  on('command.run', async ($, e, next) => {
    if (!registered.has(e.command)) return next(e)
    if (!configured) return { text: 'fixer is not set up in this folder yet.' }
    await loadTheme($)
    const name = await read($, command)
    const title = name.charAt(0).toUpperCase() + name.slice(1)
    const arg = e.args.trim().toLowerCase()

    if (arg === 'list') {
      const current = await read($, sprite)
      $.ui.toast(`Animations: ${ANIMATION_NAMES.map(a => (a === current ? `[${a}]` : a)).join(', ')}. Pick one with /${name} <name>`)
      return {}
    }
    if (arg !== '' && !ANIMATION_NAMES.includes(arg)) {
      $.ui.toast(`No animation called "${arg}". Try: ${ANIMATION_NAMES.join(', ')}`)
      return {}
    }

    // An animation name switches to it (and turns quiet mode on); no argument toggles.
    const now = arg !== '' ? true : !(await read($, calm))
    const values: Record<string, string> = { calm: now ? 'on' : 'off' }
    if (arg !== '') values.calm_animation = arg
    if (!(await writeConf($, values))) {
      $.ui.toast(`${title} unchanged: could not write config/fixer.conf`)
      return {}
    }
    await update($, calm, () => now)
    await loadTheme($)
    if (!now) stopAnimation()
    $.ui.toast(arg !== '' ? `${title} on · ${arg}` : `${title} ${now ? 'on' : 'off'}`)
    return {}
  })

  // List only the current theme's name in the menu; the others still work if typed.
  on('command.describe', async ($, e, next) => {
    if (!registered.has(e.command)) return next(e)
    const shown = await next(e)
    return { ...shown, isHidden: e.command !== (await read($, command)) }
  })

  // The animation runs only while a turn does.
  on('turn.start', async ($, e, next) => {
    stopAnimation()
    if (configured && (await read($, calm)) && ANIMATIONS[await read($, sprite)]) {
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
    if (!configured || !(await read($, calm))) return next(e)
    const animate = ANIMATIONS[await read($, sprite)]
    if (!animate) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const width = Math.max(8, (e.viewport?.columns ?? 80) - 4)
    const rows = animate(width, await read($, frame), await read($, words))
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
    const title = await read($, label)
    const { Box, Text } = $.ui.resolve(e)
    const color = (s: string) =>
      s === 'running' || s === 'starting' ? CYAN : s === 'review' || s === 'reported' ? GREEN : s === 'failed' ? AMBER : MAGENTA
    const stateText = (s: string) =>
      s === 'dialog' || s === 'blocked' ? s.toUpperCase() : s === 'review' || s === 'reported' ? 'ready' : s
    return (
      <Box flexDirection="row" flexWrap="wrap">
        <Text color={MAGENTA} bold>▌{title} </Text>
        {runners.map(r => (
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
