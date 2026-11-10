import { expect, test } from 'claude-code/testing'

import { hexStream } from '../hooks/hexstream'

const FILES: Record<string, string> = {
  'config/fixer.conf': 'client_name=client\n',
  'data/jobs/api-fix/job.conf': 'id=api-fix\nstatus=running\npane=w9:p1\n',
  'data/jobs/api-fix/status.log': '',
}

const SPINNER = {
  plugin: 'fixer-lowkey',
  component: 'Spinner',
  requestId: 'main',
  props: { word: 'Sauteing', message: null, suffix: '…', mode: 'requesting' },
} as const

/** Stands in for the engine beneath the mod: the fixer files above, a store, and registrations. */
function engine(on: Parameters<Parameters<typeof test>[1]>[1], writes: string[] = []) {
  on('fs.read', (_, e) => {
    const key = Object.keys(FILES).find(k => (e.path as string).endsWith('/' + k) || e.path === k)
    const text = key === undefined ? undefined : FILES[key]
    if (text === undefined) throw new Error('missing')
    return { value: text }
  })
  on('fs.list', () => ({ value: [{ name: 'api-fix', isDirectory: true }] }))
  on('fs.write', (_, e) => (writes.push(e.text as string), { value: undefined }))
  const store = new Map<string, unknown>()
  on('store.get', (_, e) => ({ value: store.get(e.key as string) }))
  on('store.set', (_, e) => (store.set(e.key as string, e.value), { value: undefined }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '{"result":{"agents":[]}}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
}

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
})

test('lowkey is on by default: the spinner becomes the hex stream', async ($, on) => {
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...SPINNER, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /[0-9A-F]/ })).toBeDefined()
  await ui.unmount()
})

test('outside a fixer home the mod leaves the spinner alone', async ($, on) => {
  on('fs.read', () => {
    throw new Error('missing')
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...SPINNER, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /[0-9A-F]{3}/ })).toBeUndefined()
  await ui.unmount()
})

test('tool rows draw nothing and the band lists live mercs', async ($, on) => {
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const tool = await $.ui.mount({
    plugin: 'fixer-lowkey',
    surface: 'terminal',
    component: 'ToolUse',
    requestId: 't1',
    props: { tool_use_id: 't1', tool: 'Bash', input: { command: 'ls' }, isRunning: false, isErrored: false, isInterrupted: false },
  })
  expect(await tool.find({ type: 'Text', text: /ls/ })).toBeUndefined()
  await tool.unmount()

  const band = await $.ui.mount({
    plugin: 'fixer-lowkey',
    surface: 'terminal',
    component: 'AbovePrompt',
    requestId: 'band',
    props: { hasSurvey: false, isCollapsed: false, isWorking: true, maxRows: 4, bodyColumns: 80, scroll: { offset: 0, bodyRows: 4 }, view: {} },
  })
  expect(await band.find({ type: 'Text', text: /MERCS/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /api-fix/ })).toBeDefined()
  await band.unmount()
})

test('/lowkey turns it off and saves lowkey=off', async ($, on) => {
  const writes: string[] = []
  engine(on, writes)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'lowkey', args: '' })
  expect((writes[writes.length - 1] ?? '').includes('lowkey=off')).toBe(true)
})
