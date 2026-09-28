import type { EngineInterface, Register } from 'claude-code'

// Hides SecChain's secret values in the texts the model reads: the prompt, every tool result, and
// the instructions and context the engine adds. The matching is `secchain mask`'s, and this module
// only ever holds a text before and after it: no value is read, kept or compared here
// (documents/PROJECT.md, design decision 8). It is the second line behind `secchain-guard.py`,
// which stops the calls that reach for a value; this one catches a value that got through anyway.

/**
 * Whether this load has already said that `secchain mask` could not mask. Said once, because every
 * prompt and tool result would repeat it; a reload says it again.
 */
let hasReportedUnavailableSecchain = false

/**
 * Separates the texts of one call to `secchain mask`, so that a tool result with many strings
 * costs one process instead of one per string. A NUL is not in a text a person types or a value
 * `secchain set` reads, and a text that holds one is masked on its own instead.
 */
const TEXT_SEPARATOR = '\u0000'

/**
 * The command to run: the symbolic link `make cli` installs, or `secchain` from PATH for an
 * installation that put it elsewhere (Homebrew's cask).
 */
async function secchainExecutable($: EngineInterface): Promise<string> {
  const home = await $.env.get('HOME')
  const installedPath = home === undefined ? undefined : `${home}/.local/bin/secchain`
  return installedPath !== undefined && (await $.fs.exists(installedPath)) ? installedPath : 'secchain'
}

/**
 * `text` as `secchain mask` writes it back, or `text` itself when `secchain` cannot be run or
 * fails: a hook that stops every prompt helps nobody, and `secchain-guard.py` still stands.
 *
 * `$.process.spawn` rather than `$.process.run`: `run` cuts the output at 4 MiB (4,194,304
 * characters, measured with Claude Code 2.1.283), which would drop the end of a long tool result,
 * while `spawn` hands every piece. The child runs in the session's working directory, the default
 * of both, which is how `secchain mask` finds the repository; no `--env`, so that the values of
 * every environment are looked for.
 */
async function maskedText($: EngineInterface, text: string): Promise<string> {
  if (text === '') {
    return text
  }
  try {
    const child = $.process.spawn({ argv: [await secchainExecutable($), 'mask'], input: text })
    let output = ''
    for await (const piece of child) {
      if (piece.stream === 'stdout') {
        output += piece.text
      }
    }
    const ended = await child.result
    if (ended.code !== 0) {
      // An installation older than `mask`, or a Keychain that cannot be read.
      reportUnmasked($, `secchain mask exited with ${ended.code ?? ended.signal}`)
      return text
    }
    return output
  } catch (error) {
    reportUnmasked($, `secchain could not be run: ${String(error)}`)
    return text
  }
}

/**
 * Tells the transcript, once per load, that texts now reach the model unmasked, so that the person
 * knows the protection stopped instead of assuming it still runs.
 */
function reportUnmasked($: EngineInterface, reason: string): void {
  if (hasReportedUnavailableSecchain) {
    return
  }
  hasReportedUnavailableSecchain = true
  $.ui.log(`secchain-mask: ${reason}, so texts reach the model without masking. Install a secchain that has 'mask' with 'make cli' or put it on PATH.`)
}

/**
 * `texts` with SecChain's values hidden, in order: one `secchain mask` for all of them, or one each
 * when a text holds the separator or the joined result does not split back into as many texts.
 */
async function maskedTexts($: EngineInterface, texts: readonly string[]): Promise<string[]> {
  if (!texts.some(text => text.includes(TEXT_SEPARATOR))) {
    const parts = (await maskedText($, texts.join(TEXT_SEPARATOR))).split(TEXT_SEPARATOR)
    if (parts.length === texts.length) {
      return parts
    }
  }
  const masked: string[] = []
  for (const text of texts) {
    masked.push(await maskedText($, text))
  }
  return masked
}

/**
 * Leads a tool result that had to be answered as a refusal, so that the model does not take a call
 * that ran for one that failed.
 */
const MASKED_RESULT_NOTE =
  'secchain-mask: the tool ran. This is its result as you would have read it, with SecChain secret values replaced by ***; it arrives as an error only because a plugin cannot hand back a changed result any other way.'

/**
 * Every string and number in a tool's result, with the object keys: what the model could read of a
 * result that carries no text from the engine (one a hook beneath answered).
 */
function textsOf(value: unknown): string[] {
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'bigint') {
    return [String(value)]
  }
  if (Array.isArray(value)) {
    return value.flatMap(textsOf)
  }
  if (value !== null && typeof value === 'object') {
    return Object.entries(value).flatMap(([key, item]) => [key, ...textsOf(item)])
  }
  return []
}

/** Whether `masked` differs from `texts` anywhere, which is when an answer has to be rewritten. */
function hasChanged(texts: readonly string[], masked: readonly string[]): boolean {
  return masked.some((text, index) => text !== texts[index])
}

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    const texts = [e.text, ...(e.context ?? [])]
    const masked = await maskedTexts($, texts)
    if (!hasChanged(texts, masked)) {
      return next(e)
    }
    const [text = e.text, ...context] = masked
    return next({ ...e, text, ...(e.context === undefined ? {} : { context }) })
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.isError === true) {
      // A hook cannot answer an error itself; a deny is what the model reads as one.
      const errorTexts = [ran.text ?? textsOf(ran.result).join('\n'), ...(ran.context ?? [])]
      const maskedErrorTexts = await maskedTexts($, errorTexts)
      return hasChanged(errorTexts, maskedErrorTexts) ? { deny: maskedErrorTexts.join('\n\n') } : ran
    }
    if (ran.deny !== undefined) {
      // A refusal from beneath reaches the model as an error text too.
      const deny = await maskedText($, ran.deny)
      return deny === ran.deny ? ran : { deny }
    }
    // What the model reads is the engine's text, not the tool's record: a value only in the record
    // (the content a Write sent) does not reach it. A record rewritten in place would be mapped to
    // text again by the tool, which may add words of its own or refuse a field that no longer fits
    // its schema, so the masked text itself is what the model gets.
    const texts = [ran.text ?? textsOf(ran.result).join('\n'), ...(ran.context ?? [])]
    const masked = await maskedTexts($, texts)
    if (!hasChanged(texts, masked)) {
      // The engine's own answer, `ref` included, so that it uses its messages as they are.
      return ran
    }
    return { deny: [MASKED_RESULT_NOTE, ...masked].join('\n\n') }
  })

  on('prompt.section', async ($, e, next) => {
    const section = await next(e)
    if (section.text === null) {
      return section
    }
    const text = await maskedText($, section.text)
    return text === section.text ? section : { text }
  })

  on('prompt.context', async ($, e, next) => {
    const context = await next(e)
    const texts = context.blocks.map(block => block.text)
    const masked = await maskedTexts($, texts)
    if (!hasChanged(texts, masked)) {
      return context
    }
    return { ...context, blocks: context.blocks.map((block, index) => ({ ...block, text: masked[index] ?? block.text })) }
  })

  on('prompt.attachment', async ($, e, next) => {
    const attachment = await next(e)
    if (attachment.text === null) {
      return attachment
    }
    const text = await maskedText($, attachment.text)
    return text === attachment.text ? attachment : { text }
  })
}
