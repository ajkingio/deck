import type { On } from 'claude-code'
import { expect, mock, test, type Engine } from 'claude-code/testing'

import { hexStream } from '../hooks/hexstream'
import { classifyRestored, isWorkingNote, noteKey, PRESERVE_MIN_CHARS } from '../hooks/narration'

const BASE: Record<string, string> = {
  'config/fixer.conf': 'client_name=client\n',
  'data/jobs/api-fix/job.conf': 'id=api-fix\nstatus=running\npane=w9:p1\n',
  'data/jobs/api-fix/status.log': '',
}

const SPINNER = {
  plugin: 'fixer-lowkey',
  surface: 'terminal',
  component: 'Spinner',
  requestId: 'main',
  props: { word: 'Sauteing', message: null, suffix: '…', mode: 'requesting' },
} as const

function band(isWorking: boolean, isCollapsed = false) {
  return {
    plugin: 'fixer-lowkey',
    surface: 'terminal',
    component: 'AbovePrompt',
    requestId: 'band',
    props: { hasSurvey: false, isCollapsed, isWorking, maxRows: 8, bodyColumns: 60, scroll: { offset: 0, bodyRows: 8 }, view: {} },
  } as const
}

function assistant(text: string, requestId = 'a1') {
  return {
    plugin: 'fixer-lowkey',
    surface: 'terminal',
    component: 'AssistantMessage',
    requestId,
    props: { text, isFirstOfReply: true },
  } as const
}

const COMMAND = {
  command: 'lowkey',
  args: '',
  origin: { kind: 'composer' },
  presentation: { layout: 'main', isFullscreen: false, columns: 80 },
} as const

type World = {
  files?: Record<string, string>
  writes?: string[]
  /** Herdr's agent_status for pane w9:p1, or none listed. */
  herdr?: string
  /** What $.session.messages() returns at session start. */
  messages?: Array<{ role: 'user' | 'assistant'; text: string; toolUses: unknown[] }>
}

/** Stands in for the engine beneath the mod: the fixer files, a store, a clock, Herdr, and registrations. */
function engine(on: On, w: World = {}) {
  const files = w.files ?? BASE
  on('fs.read', (_, e) => {
    const key = Object.keys(files).find(k => (e.path as string).endsWith('/' + k) || e.path === k)
    const text = key === undefined ? undefined : files[key]
    if (text === undefined) throw new Error('missing')
    return { value: text }
  })
  on('fs.list', () => ({
    value: [...new Set(Object.keys(files).filter(k => k.startsWith('data/jobs/')).map(k => k.split('/')[2]!))].map(name => ({
      name,
      kind: 'dir' as const,
      size: 0,
      mtimeMs: 0,
      isLink: false,
    })),
  }))
  on('fs.write', (_, e) => (w.writes?.push(e.text as string), { value: undefined }))
  mock.store(on)
  const clock = mock.clock(on)
  const agents = w.herdr === undefined ? [] : [{ pane_id: 'w9:p1', agent_status: w.herdr }]
  on('process.run', () => ({
    value: { exitCode: 0, stdout: JSON.stringify({ result: { agents } }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('session.messages', () => ({ value: (w.messages ?? []) as never }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.start', (_, e) => ({ turnId: (e as { turnId: string }).turnId }) as never)
  on('turn.complete', () => ({ text: '' }) as never)
  return { clock }
}

const START = { cwd: '/', surface: 'terminal', isInteractive: true } as const
const text = (tree: unknown) => JSON.stringify(tree)
const isHidden = (tree: unknown) => text(tree).includes('"display":"none"')
/** The hex-stream rows: runs of hex/binary at least 6 wide (the MERCS row has none). */
const hasStream = (tree: unknown) => /[0-9A-F ]{6,}/.test(text(tree).replace(/api-fix/g, ''))

// ------------------------------------------------------------------ pure parts

test('the hex stream fills exactly the row width, with a glitch column sweeping across', () => {
  for (const width of [8, 37, 120]) {
    for (const f of [0, 1, 7, 40, 333, 5000]) {
      const rows = hexStream(width, f)
      expect(rows.length).toBe(2)
      for (const r of rows) expect([...r.map(s => s.text).join('')].length).toBe(width)
    }
  }
  const seen = Array.from({ length: 80 }, (_, f) => hexStream(60, f)[0]!.some(s => s.text.includes('▌')))
  expect(seen.some(Boolean)).toBe(true)
  expect(text(hexStream(40, 3, '#123456'))).toContain('#123456')
})

test('a working note is short, single-line text from a step that stopped to call tools', () => {
  const tools = { stopReason: 'tool_use', toolUses: [{}] }
  expect(isWorkingNote(tools, 'Let me check the logs.')).toBe(true)
  expect(isWorkingNote(tools, 'First line.\nSecond line.')).toBe(false)
  expect(isWorkingNote(tools, 'x'.repeat(PRESERVE_MIN_CHARS))).toBe(false)
  expect(isWorkingNote({ stopReason: 'end_turn', toolUses: [] }, 'Done.')).toBe(false)
  expect(isWorkingNote({ stopReason: 'max_tokens', toolUses: [{}] }, 'Reading.')).toBe(true)
  expect(isWorkingNote({ stopReason: 'max_tokens', toolUses: [] }, 'Reading.')).toBe(false)
  expect(noteKey('  hi  ')).toBe('hi')
  expect(noteKey('hi\n')).toBe('hi\n')
})

test('a restored transcript marks narration before tool calls, and keeps replies', () => {
  const { notes, replies } = classifyRestored([
    { role: 'user', text: 'fix it', toolUses: [] },
    { role: 'assistant', text: 'Looking.', toolUses: [] },
    { role: 'assistant', text: '', toolUses: [{}] },
    { role: 'assistant', text: 'Fixed it.', toolUses: [] },
    { role: 'user', text: 'thanks', toolUses: [] },
    { role: 'assistant', text: 'Looking.', toolUses: [] },
  ])
  expect(notes).toEqual([])
  expect(replies).toContain('Fixed it.')
  expect(replies).toContain('Looking.') // once a reply, always visible
  expect(classifyRestored([{ role: 'assistant', text: 'Checking.', toolUses: [{}] }]).notes).toEqual(['Checking.'])
})

// --------------------------------------------------------------- the engine glue

test('lowkey is on by default: the spinner becomes the hex stream', async ($, on) => {
  engine(on)
  await $.session.start(START)
  const ui = await $.ui.mount(SPINNER)
  expect(await ui.find({ type: 'Text', text: /[0-9A-F]/ })).toBeDefined()
  await ui.unmount()
})

test('outside a fixer home the mod leaves the spinner alone', async ($, on) => {
  on('fs.read', () => {
    throw new Error('missing')
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start(START)
  const ui = await $.ui.mount(SPINNER)
  expect(await ui.find({ type: 'Text', text: /[0-9A-F]{3}/ })).toBeUndefined()
  await ui.unmount()
})

test('tool rows draw nothing', async ($, on) => {
  engine(on)
  await $.session.start(START)
  const tool = await $.ui.mount({
    plugin: 'fixer-lowkey',
    surface: 'terminal',
    component: 'ToolUse',
    requestId: 't1',
    props: { tool_use_id: 't1', tool: 'Bash', input: { command: 'ls' }, isRunning: false, isErrored: false, isInterrupted: false },
  })
  expect(await tool.find({ type: 'Text', text: /ls/ })).toBeUndefined()
  await tool.unmount()
})

test('during a turn the MERCS row sits above the stream in the spinner, and the band draws nothing', async ($, on) => {
  engine(on, { herdr: 'working' })
  await $.session.start(START)
  const spinner = text(await $.ui.render(SPINNER))
  const mercs = spinner.indexOf('MERCS')
  expect(mercs).toBeGreaterThan(-1)
  expect(spinner.indexOf('api-fix')).toBeGreaterThan(mercs)
  // every stream row comes after the MERCS row
  const firstStream = spinner.search(/"[0-9A-F01 ]{6,}/)
  expect(firstStream).toBeGreaterThan(mercs)
  const inTurn = text(await $.ui.render(band(true)))
  expect(inTurn.includes('MERCS')).toBe(false)
})

test('between turns, with a merc working, the band draws MERCS above a dimmer stream sized to the body', async ($, on) => {
  engine(on, { herdr: 'working' })
  await $.session.start(START)
  const tree = text(await $.ui.render(band(false)))
  expect(tree.indexOf('MERCS')).toBeGreaterThan(-1)
  expect(tree.search(/"[0-9A-F01 ]{6,}/)).toBeGreaterThan(tree.indexOf('api-fix'))
  expect(tree).toContain('#00b4bc')
  const collapsed = text(await $.ui.render(band(false, true)))
  expect(collapsed).toContain('MERCS')
  expect(collapsed.includes('#00b4bc')).toBe(false)
})

for (const herdr of ['idle', 'done', 'blocked']) {
  test(`between turns the band does not animate when Herdr sees the merc ${herdr}`, async ($, on) => {
    engine(on, { herdr })
    await $.session.start(START)
    const tree = text(await $.ui.render(band(false)))
    expect(tree).toContain('MERCS')
    expect(tree.includes('#00b4bc')).toBe(false)
  })
}

test('a reported merc is listed but does not animate the band', async ($, on) => {
  engine(on, {
    files: { ...BASE, 'data/jobs/api-fix/job.conf': 'id=api-fix\nstatus=review\npane=w9:p1\n' },
  })
  await $.session.start(START)
  const tree = text(await $.ui.render(band(false)))
  expect(tree).toContain('ready')
  expect(tree.includes('#00b4bc')).toBe(false)
})

test('the frame timer runs between turns while a merc works, and stops when none does', async ($, on) => {
  const files = { ...BASE }
  const { clock } = engine(on, { files, herdr: 'working' })
  await $.session.start(START)
  const a = text(await $.ui.render(band(false)))
  await clock.advance(120 * 10)
  const b = text(await $.ui.render(band(false)))
  expect(b === a).toBe(false) // the stream moved with no turn running

  files['data/jobs/api-fix/job.conf'] = 'id=api-fix\nstatus=review\npane=w9:p1\n'
  await clock.advance(3000) // one poll notices the merc reported
  const c = text(await $.ui.render(SPINNER))
  await clock.advance(120 * 10)
  const d = text(await $.ui.render(SPINNER))
  expect(d).toBe(c) // frame frozen: no turn, no working merc
})

test('the frame timer runs during a turn even with no mercs', async ($, on) => {
  const { clock } = engine(on, { files: { 'config/fixer.conf': 'client_name=client\n' } })
  await $.session.start(START)
  const a = text(await $.ui.render(SPINNER))
  await clock.advance(1200)
  expect(text(await $.ui.render(SPINNER))).toBe(a)
  await $.turn.start({ turnId: 't', prompt: 'hi' } as never)
  await clock.advance(1200)
  expect(text(await $.ui.render(SPINNER)) === a).toBe(false)
})

test('/lowkey turns it off, saves lowkey=off, and stops hiding', async ($, on) => {
  const writes: string[] = []
  engine(on, { writes, herdr: 'working' })
  await $.session.start(START)
  await $.command.run(COMMAND)
  expect((writes[writes.length - 1] ?? '').includes('lowkey=off')).toBe(true)
  expect(text(await $.ui.render(band(false))).includes('MERCS')).toBe(false)
})

// -------------------------------------------------------------- narration hiding

type Chunk = { kind: 'text'; index: number; text: string } | { kind: 'tool'; index: number; id: string; name: string } | { kind: 'stop'; stopReason: string; usage: null }

function stepper(on: On) {
  const s: { chunks: Chunk[]; answer: string; stopReason: string; tools: number } = { chunks: [], answer: '', stopReason: 'end_turn', tools: 0 }
  on('turn.step', async function* (_$, e) {
    for (const c of s.chunks) yield c as never
    return {
      turnId: e.turnId,
      index: e.index,
      usage: null,
      answer: s.answer,
      stopReason: s.stopReason,
      toolUses: Array.from({ length: s.tools }, () => ({ name: 'Bash', input: {} })),
    } as never
  })
  return (next: typeof s) => Object.assign(s, next)
}

async function runStep($: Engine, agentId?: string) {
  const stream = $.turn.step({ turnId: 't', index: 0, model: 'haiku', messageCount: 1, ...(agentId ? { agentId } : {}) } as never)
  const seen: unknown[] = []
  let r = await stream.next()
  while (!r.done) {
    seen.push(r.value)
    r = await stream.next()
  }
  return { seen, result: r.value as { answer: string } }
}

test('short narration before a tool call is hidden; long, multi-line and final text stays; the stream is untouched', async ($, on) => {
  engine(on)
  const set = stepper(on)
  await $.session.start(START)
  const long = 'x'.repeat(PRESERVE_MIN_CHARS + 5)
  set({
    chunks: [
      { kind: 'text', index: 0, text: 'Let me ' },
      { kind: 'text', index: 0, text: 'look first.' },
      { kind: 'tool', index: 1, id: 't1', name: 'Bash' },
      { kind: 'text', index: 2, text: 'Line one.\nLine two.' },
      { kind: 'text', index: 3, text: long },
      { kind: 'stop', stopReason: 'tool_use', usage: null },
    ],
    answer: `Let me look first.\nLine one.\nLine two.\n${long}`,
    stopReason: 'tool_use',
    tools: 1,
  })
  expect(isHidden(await $.ui.render(assistant('Let me look first.')))).toBe(false)
  const { seen, result } = await runStep($)
  expect(seen.length).toBe(6)
  expect(result.answer.startsWith('Let me look first.')).toBe(true)
  expect(isHidden(await $.ui.render(assistant('Let me look first.')))).toBe(true)
  expect(isHidden(await $.ui.render(assistant('Line one.\nLine two.')))).toBe(false)
  expect(isHidden(await $.ui.render(assistant(long)))).toBe(false)

  set({ chunks: [{ kind: 'text', index: 0, text: 'All done.' }, { kind: 'stop', stopReason: 'end_turn', usage: null }], answer: 'All done.', stopReason: 'end_turn', tools: 0 })
  await runStep($)
  expect(isHidden(await $.ui.render(assistant('All done.')))).toBe(false)
})

test('a final reply that matches an earlier note is shown again', async ($, on) => {
  engine(on)
  const set = stepper(on)
  await $.session.start(START)
  set({ chunks: [{ kind: 'text', index: 0, text: 'Done.' }], answer: 'Done.', stopReason: 'tool_use', tools: 1 })
  await runStep($)
  expect(isHidden(await $.ui.render(assistant('Done.')))).toBe(true)
  set({ chunks: [{ kind: 'text', index: 0, text: 'Done.' }], answer: 'Done.', stopReason: 'end_turn', tools: 0 })
  await runStep($)
  expect(isHidden(await $.ui.render(assistant('Done.')))).toBe(false)
})

test('subagent steps, lowkey off, and restored transcripts', async ($, on) => {
  engine(on, {
    writes: [],
    messages: [
      { role: 'user', text: 'go', toolUses: [] },
      { role: 'assistant', text: 'Checking the board.', toolUses: [{}] },
      { role: 'assistant', text: 'All clear.', toolUses: [] },
    ],
  })
  const set = stepper(on)
  await $.session.start(START)
  expect(isHidden(await $.ui.render(assistant('Checking the board.')))).toBe(true)
  expect(isHidden(await $.ui.render(assistant('All clear.')))).toBe(false)

  set({ chunks: [{ kind: 'text', index: 0, text: 'Sub note.' }], answer: 'Sub note.', stopReason: 'tool_use', tools: 1 })
  await runStep($, 'agent-1')
  expect(isHidden(await $.ui.render(assistant('Sub note.')))).toBe(false)

  await $.command.run(COMMAND) // lowkey off
  expect(isHidden(await $.ui.render(assistant('Checking the board.')))).toBe(false)
})
