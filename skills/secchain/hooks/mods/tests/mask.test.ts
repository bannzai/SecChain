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
  /** The refusal a masked tool result arrives as: the note, then the masked texts. */
  function maskedResult(...texts: string[]): { deny: string } {
    return {
      deny: [
        'secchain-mask: the tool ran. This is its result as you would have read it, with SecChain secret values replaced by ***; it arrives as an error only because a plugin cannot hand back a changed result any other way.',
        ...texts,
      ].join('\n\n'),
    }
  }

  test('a tool result whose text holds the value reaches the model as that text masked', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({
      ref: 1,
      text: `token=${DUMMY_VALUE}\nsecond ${DUMMY_VALUE}`,
      result: { stdout: `token=${DUMMY_VALUE}\nsecond ${DUMMY_VALUE}`, stderr: '', interrupted: false },
      context: [`note ${DUMMY_VALUE}`],
    }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'cat config' })
    expect(ran).toEqual(maskedResult('token=***\nsecond ***', 'note ***'))
    // The text and the context went through one secchain mask.
    expect(fake.argvs).toHaveLength(1)
  })

  test('a tool result without the value is the engine answer as it was', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 7, text: 'hello', result: { stdout: 'hello', stderr: '', interrupted: false } }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'echo hello' })
    expect(ran).toEqual({ ref: 7, text: 'hello', result: { stdout: 'hello', stderr: '', interrupted: false } })
  })

  test('a value only in the record, which the model does not read, leaves the answer as it was', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 8, text: 'File created successfully at: config.txt', result: { type: 'create', filePath: 'config.txt', content: DUMMY_VALUE } }))
    const ran = await $.tool.call({ tool: 'Write', file_path: 'config.txt', content: 'x' })
    expect(ran).toEqual({ ref: 8, text: 'File created successfully at: config.txt', result: { type: 'create', filePath: 'config.txt', content: DUMMY_VALUE } })
  })

  test('a result a hook beneath answered is judged by its keys, strings and numbers', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ result: { [DUMMY_VALUE]: 1 } }))
    expect(await $.tool.call({ tool: 'mcp__example__lookup' })).toEqual(maskedResult('***\n1'))
  })

  test('an error with the value reaches the model masked, as a refusal', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ isError: true, ref: 2, text: `failed with ${DUMMY_VALUE}`, result: `failed with ${DUMMY_VALUE}` }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'false' })
    expect(ran).toEqual({ deny: 'failed with ***' })
  })

  test('an error without text is judged by its record and its context', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ isError: true, result: 'failed', context: [`note ${DUMMY_VALUE}`] }))
    expect(await $.tool.call({ tool: 'Bash', command: 'false' })).toEqual({ deny: 'failed\n\nnote ***' })
  })

  test('a refusal from beneath with the value reaches the model masked', async ($, on) => {
    fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ deny: `refused ${DUMMY_VALUE}` }))
    expect(await $.tool.call({ tool: 'Bash', command: 'true' })).toEqual({ deny: 'refused ***' })
  })

  test('a text that holds the separator is masked on its own', async ($, on) => {
    const fake = fakeHost(on, { isInstalled: true })
    on('tool.call', () => ({ ref: 3, text: `a\u0000${DUMMY_VALUE}`, result: { stdout: '', stderr: '', interrupted: false }, context: [DUMMY_VALUE] }))
    const ran = await $.tool.call({ tool: 'Bash', command: 'cat binary' })
    expect(ran).toEqual(maskedResult('a\u0000***', '***'))
    expect(fake.argvs).toHaveLength(2)
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
