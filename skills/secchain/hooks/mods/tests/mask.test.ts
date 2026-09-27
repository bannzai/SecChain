import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// Checks of the secchain-mask plugin, run with `claude plugin test` (make test-hooks). Nothing here
// reaches the Keychain: the hooks of the test stand for the host beneath the plugin, and the one on
// `process.spawn` is the fake `secchain mask`, replacing a fixed dummy value with `***` the way
// the real command replaces a stored one.

const DUMMY_VALUE = 'dummy-value-for-hook-test'
const HOME = '/Users/someone'
const INSTALLED_SECCHAIN = `${HOME}/.local/bin/secchain`

/** What the fake `secchain` saw and how the test wants it to answer. */
type FakeSecchain = {
  argvs: string[][]
  logs: string[]
}

/**
 * Stands for the host: `HOME`, whether `make cli`'s link exists, the `secchain` process, and the
 * transcript lines. `exitCode` is what the fake command exits with; `isMissing` makes it fail to
 * start, as a command that is not installed does.
 */
function fakeHost(on: On, options: { isInstalled: boolean; isMissing?: boolean; exitCode?: number }): FakeSecchain {
  const fake: FakeSecchain = { argvs: [], logs: [] }
  mock.env(on, { HOME })
  on('fs.exists', ($, e) => ({ value: options.isInstalled && e.path === INSTALLED_SECCHAIN }))
  on('process.spawn', async function* ($, e) {
    fake.argvs.push([...e.argv])
    if (options.isMissing === true) {
      throw new Error(`ENOENT: Executable not found in $PATH: "${e.argv[0]}"`)
    }
    yield { stream: 'stdout' as const, text: (e.input ?? '').split(DUMMY_VALUE).join('***') }
    return { value: { code: options.exitCode ?? 0, signal: null } }
  })
  on('ui.log', ($, e) => {
    fake.logs.push(e.text)
    return { value: undefined }
  })
  return fake
}

describe('prompt.submit', () => {
  test('the prompt that enters has the value masked', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: true })
    const entered: string[] = []
    on('prompt.submit', ($, e) => {
      entered.push(e.text)
      return { text: e.text }
    })
    await $.prompt.submit({ text: `use ${DUMMY_VALUE} here`, wait: false, origin: { kind: 'composer' } })
    expect(entered).toEqual(['use *** here'])
    expect(fake.argvs).toEqual([[INSTALLED_SECCHAIN, 'mask']])
  })

  test('secchain is taken from PATH when make cli did not install it', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: false })
    on('prompt.submit', ($, e) => ({ text: e.text }))
    await $.prompt.submit({ text: 'nothing secret', wait: false, origin: { kind: 'composer' } })
    expect(fake.argvs).toEqual([['secchain', 'mask']])
  })

  test('without secchain the prompt passes unchanged and the transcript is told once', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: false, isMissing: true })
    const entered: string[] = []
    on('prompt.submit', ($, e) => {
      entered.push(e.text)
      return { text: e.text }
    })
    await $.prompt.submit({ text: `first ${DUMMY_VALUE}`, wait: false, origin: { kind: 'composer' } })
    await $.prompt.submit({ text: `second ${DUMMY_VALUE}`, wait: false, origin: { kind: 'composer' } })
    expect(entered).toEqual([`first ${DUMMY_VALUE}`, `second ${DUMMY_VALUE}`])
    expect(fake.logs.filter(line => line.includes('secchain could not be run'))).toHaveLength(1)
  })

  test('a failing secchain mask leaves the prompt as it was and the transcript is told once', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: true, exitCode: 1 })
    const entered: string[] = []
    on('prompt.submit', ($, e) => {
      entered.push(e.text)
      return { text: e.text }
    })
    await $.prompt.submit({ text: `use ${DUMMY_VALUE}`, wait: false, origin: { kind: 'composer' } })
    await $.prompt.submit({ text: `again ${DUMMY_VALUE}`, wait: false, origin: { kind: 'composer' } })
    expect(entered).toEqual([`use ${DUMMY_VALUE}`, `again ${DUMMY_VALUE}`])
    expect(fake.logs.filter(line => line.includes('secchain mask exited with 1'))).toHaveLength(1)
  })
})

describe('tool.call', () => {
  test('a tool result with the value reaches the model masked, as a record of its own', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({
      ref: 1,
      text: `token=${DUMMY_VALUE}`,
      result: { stdout: `token=${DUMMY_VALUE}`, stderr: '', interrupted: false, lines: [`a ${DUMMY_VALUE}`, 'b'] },
    }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'cat config' })
    expect(ran).toEqual({ result: { stdout: 'token=***', stderr: '', interrupted: false, lines: ['a ***', 'b'] } })
    expect(ran).not.toHaveProperty('ref')
    // Every string of the record went through one secchain mask.
    expect(fake.argvs).toHaveLength(1)
  })

  test('a tool result without the value is the engine answer as it was', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 7, text: 'hello', result: { stdout: 'hello', stderr: '', interrupted: false } }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'echo hello' })
    expect(ran).toEqual({ ref: 7, text: 'hello', result: { stdout: 'hello', stderr: '', interrupted: false } })
  })

  test('an error with the value reaches the model masked, as a refusal', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ isError: true, ref: 2, text: `failed with ${DUMMY_VALUE}`, result: `failed with ${DUMMY_VALUE}` }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'false' })
    expect(ran).toEqual({ deny: 'failed with ***' })
  })

  test('a string that holds the separator is masked on its own', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 3, text: '', result: { stdout: `a\u0000${DUMMY_VALUE}`, stderr: DUMMY_VALUE, interrupted: false } }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'cat binary' })
    expect(ran).toEqual({ result: { stdout: 'a\u0000***', stderr: '***', interrupted: false } })
    expect(fake.argvs.length).toBeGreaterThan(1)
  })

  test('a refusal from beneath with the value reaches the model masked', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ deny: `refused ${DUMMY_VALUE}` }))
    expect(await $.tool.call({ tool: 'Bash', command: 'true' })).toEqual({ deny: 'refused ***' })
  })

  test('a value in a key of the record is withheld as the masked text the model would read', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 4, text: `${DUMMY_VALUE}: 1`, result: { [DUMMY_VALUE]: 1 } }))
    expect(await $.tool.call({ tool: 'mcp__example__lookup' })).toEqual({ deny: '***: 1' })
  })

  test('a value only in the text the model reads is withheld as that text masked', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 5, text: `token=${DUMMY_VALUE}`, result: { count: 2 } }))
    expect(await $.tool.call({ tool: 'mcp__example__lookup' })).toEqual({ deny: 'token=***' })
  })
})

describe('the texts the engine adds', () => {
  test('a system prompt section is masked', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('prompt.section', ($, e) => ({ text: e.text }))
    expect(await $.prompt.section({ name: 'memory', text: `remember ${DUMMY_VALUE}` })).toEqual({ text: 'remember ***' })
  })

  test('the context blocks of the first message are masked', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('prompt.context', ($, e) => ({ blocks: e.blocks }))
    const context = await $.prompt.context({ blocks: [{ name: 'claudeMd', text: `key ${DUMMY_VALUE}` }, { name: 'currentDate', text: 'today' }] })
    expect(context.blocks).toEqual([{ name: 'claudeMd', text: 'key ***' }, { name: 'currentDate', text: 'today' }])
  })

  test('an attachment such as a mentioned file is masked', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('prompt.attachment', ($, e) => ({ text: e.text }))
    expect(await $.prompt.attachment({ type: 'file', text: `API_KEY=${DUMMY_VALUE}`, origin: { kind: 'engine' } })).toEqual({ text: 'API_KEY=***' })
  })
})
