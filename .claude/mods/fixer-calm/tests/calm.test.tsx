import { expect, test } from 'claude-code/testing'

import { hexStream } from '../hooks/register'

const FILES: Record<string, string> = {
  'config/fixer.conf': 'theme=cyberpunk-netrunner\nclient_name=runner\ncalm=on\n',
  'themes/cyberpunk-netrunner.md': '---\nname: cyberpunk-netrunner\ndescription: x\ncalm: hex-stream\ncalm_command: ghost\ncrew_label: daemons\n---\nbody\n',
  'data/jobs/api-fix/job.conf': 'id=api-fix\nstatus=running\npane=w9:p1\n',
  'data/jobs/api-fix/status.log': '',
}

const SPINNER = {
  plugin: 'fixer-calm',
  component: 'Spinner',
  requestId: 'main',
  props: { word: 'Sauteing', message: null, suffix: '…', mode: 'requesting' },
} as const

test('the hex stream fills the width in two rows, with one sweeping glitch column', () => {
  for (const f of [0, 7, 40, 500]) {
    const rows = hexStream(60, f)
    expect(rows.length).toBe(2)
    for (const [before, glitch, after] of rows) {
      expect(before.length + glitch.length + after.length).toBe(60)
      expect(/^[0-9A-F ]*$/.test(before + after)).toBe(true)
    }
  }
  // Somewhere in a sweep the glitch column is on screen.
  const seen = Array.from({ length: 80 }, (_, f) => hexStream(60, f)[0]![1]).filter(g => g.startsWith('▌'))
  expect(seen.length > 0).toBe(true)
})

test('with calm on in a fixer home, the spinner becomes the hex stream', async ($, on) => {
  on('fs.read', (_, e) => {
    const key = Object.keys(FILES).find(k => (e.path as string).endsWith('/' + k) || e.path === k)
    const text = key === undefined ? undefined : FILES[key]
    if (text === undefined) throw new Error('missing ' + JSON.stringify(e))
    return { value: text }
  })
  on('fs.list', () => ({ value: [{ name: 'api-fix', isDirectory: true }] }))
  on('fs.write', () => ({ value: undefined }))
  const store = new Map<string, unknown>()
  on('store.get', (_, e) => ({ value: store.get(e.key as string) }))
  on('store.set', (_, e) => (store.set(e.key as string, e.value), { value: undefined }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '{"result":{"agents":[]}}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('command.register', () => ({ value: { command: 'calm' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...SPINNER, surface: 'terminal' })
  const row = await ui.find({ type: 'Text', text: /[0-9A-F]/ })
  expect(row).toBeDefined()
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

test('with calm on, tool rows draw nothing and the crew band lists live runners', async ($, on) => {
  on('fs.read', (_, e) => {
    const key = Object.keys(FILES).find(k => (e.path as string).endsWith('/' + k) || e.path === k)
    const text = key === undefined ? undefined : FILES[key]
    if (text === undefined) throw new Error('missing ' + JSON.stringify(e))
    return { value: text }
  })
  on('fs.list', () => ({ value: [{ name: 'api-fix', isDirectory: true }] }))
  on('fs.write', () => ({ value: undefined }))
  const store = new Map<string, unknown>()
  on('store.get', (_, e) => ({ value: store.get(e.key as string) }))
  on('store.set', (_, e) => (store.set(e.key as string, e.value), { value: undefined }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '{"result":{"agents":[]}}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('command.register', () => ({ value: { command: 'calm' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const tool = await $.ui.mount({
    plugin: 'fixer-calm',
    surface: 'terminal',
    component: 'ToolUse',
    requestId: 't1',
    props: { tool_use_id: 't1', tool: 'Bash', input: { command: 'ls' }, isRunning: false, isErrored: false, isInterrupted: false },
  })
  expect(await tool.find({ type: 'Text', text: /ls/ })).toBeUndefined()
  await tool.unmount()

  const band = await $.ui.mount({
    plugin: 'fixer-calm',
    surface: 'terminal',
    component: 'AbovePrompt',
    requestId: 'band',
    props: { hasSurvey: false, isCollapsed: false, isWorking: true, maxRows: 4, bodyColumns: 80, scroll: { offset: 0, bodyRows: 4 }, view: {} },
  })
  expect(await band.find({ type: 'Text', text: /DAEMONS/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /api-fix/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /running/ })).toBeDefined()
  await band.unmount()
})

test('the theme names the toggle: /ghost registers beside /calm and turns calm off', async ($, on) => {
  const names: string[] = []
  const writes: string[] = []
  on('fs.read', (_, e) => {
    const key = Object.keys(FILES).find(k => (e.path as string).endsWith('/' + k) || e.path === k)
    const text = key === undefined ? undefined : FILES[key]
    if (text === undefined) throw new Error('missing')
    return { value: text }
  })
  on('fs.list', () => ({ value: [] }))
  on('fs.write', (_, e) => (writes.push(e.text as string), { value: undefined }))
  const store = new Map<string, unknown>()
  on('store.get', (_, e) => ({ value: store.get(e.key as string) }))
  on('store.set', (_, e) => (store.set(e.key as string, e.value), { value: undefined }))
  on('command.register', (_, e) => (names.push(e.name as string), { value: { command: e.name } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  expect(names.includes('calm')).toBe(true)
  expect(names.includes('ghost')).toBe(true)

  await $.command.run({ command: 'ghost', args: '' })
  expect(writes.some(w => w.includes('calm=off'))).toBe(true)
})
