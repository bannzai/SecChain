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

/** Every string in a tool's result, in the order `withStrings` puts them back. */
function stringsOf(value: unknown): string[] {
  if (typeof value === 'string') {
    return [value]
  }
  if (Array.isArray(value)) {
    return value.flatMap(stringsOf)
  }
  if (value !== null && typeof value === 'object') {
    return Object.values(value).flatMap(stringsOf)
  }
  return []
}

/**
 * The parts of a tool's result that `withStrings` cannot rewrite: object keys and numbers, as
 * text. A value found there cannot be hidden by rewriting the record.
 */
function fixedTextsOf(value: unknown): string[] {
  if (typeof value === 'number' || typeof value === 'bigint') {
    return [String(value)]
  }
  if (Array.isArray(value)) {
    return value.flatMap(fixedTextsOf)
  }
  if (value !== null && typeof value === 'object') {
    return Object.entries(value).flatMap(([key, item]) => [key, ...fixedTextsOf(item)])
  }
  return []
}

/** `value` rebuilt with its strings taken from `strings`, in the order `stringsOf` listed them. */
function withStrings(value: unknown, strings: string[]): unknown {
  if (typeof value === 'string') {
    return strings.shift()
  }
  if (Array.isArray(value)) {
    return value.map(item => withStrings(item, strings))
  }
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, withStrings(item, strings)]))
  }
  return value
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
      if (ran.text === undefined) {
        return ran
      }
      const text = await maskedText($, ran.text)
      return text === ran.text ? ran : { deny: text }
    }
    if (ran.deny !== undefined) {
      // A refusal from beneath reaches the model as an error text too.
      const deny = await maskedText($, ran.deny)
      return deny === ran.deny ? ran : { deny }
    }
    const resultStrings = stringsOf(ran.result)
    const context = ran.context ?? []
    const fixedTexts = fixedTextsOf(ran.result)
    const modelTexts = ran.text === undefined ? [] : [ran.text]
    const texts = [...resultStrings, ...context, ...fixedTexts, ...modelTexts]
    const masked = await maskedTexts($, texts)
    if (!hasChanged(texts, masked)) {
      // The engine's own answer, `ref` included, so that it uses its messages as they are.
      return ran
    }
    const maskedResultStrings = masked.slice(0, resultStrings.length)
    const maskedContext = masked.slice(resultStrings.length, resultStrings.length + context.length)
    const hasValueInFixedText = hasChanged(fixedTexts, masked.slice(resultStrings.length + context.length, texts.length - modelTexts.length))
    const hasValueOnlyInModelText = !hasChanged([...resultStrings, ...context], [...maskedResultStrings, ...maskedContext])
    if (hasValueInFixedText || hasValueOnlyInModelText) {
      // Rewriting the record cannot hide a value in a key, a number, or text the tool's mapper adds
      // on its own, so the model gets the masked text it would have read, as an error.
      const maskedModelText = modelTexts.length === 1 ? masked[texts.length - 1] : undefined
      return { deny: maskedModelText ?? 'secchain-mask: the tool result held a SecChain secret value and was withheld.' }
    }
    // Without `ref` and `text`, the engine maps the masked record for the model instead of reusing
    // the messages it made from the original.
    return {
      result: withStrings(ran.result, maskedResultStrings),
      ...(ran.context === undefined ? {} : { context: maskedContext }),
    }
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
