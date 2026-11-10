// Which assistant text is a mid-turn working note ("Let me check the logs.")
// that /lowkey hides, and which is a reply it keeps. Adapted from firstmate's
// Calm (lib/fm-calm-preservation.ts and lib/fm-calm-presentation.ts): the same
// 240-character / newline preservation rule. Pure, so it is tested on its own.

/** Mid-turn text at least this long (trimmed) stays visible. */
export const PRESERVE_MIN_CHARS = 240

/** Whether text is substantive enough to stay visible even mid-turn. */
export function isSubstantive(text: string): boolean {
  return text.includes('\n') || text.trim().length >= PRESERVE_MIN_CHARS
}

/** The part of a `turn.step` result the rule reads. */
export type StepOutcome = { readonly stopReason: string | null; readonly toolUses: readonly unknown[] }

/**
 * Whether text from a model step is a working note: the model stopped there to
 * call tools (or ran out of tokens while calling them), and the text is short
 * and on one line. Anything else is a reply.
 */
export function isWorkingNote(step: StepOutcome, text: string): boolean {
  const midTurn = step.stopReason === 'tool_use' || (step.stopReason === 'max_tokens' && step.toolUses.length > 0)
  return midTurn && !isSubstantive(text)
}

/** How a block's text is matched to its transcript row: trimmed, keeping whether it held a newline. */
export function noteKey(text: string): string {
  const t = text.trim()
  if (t === '') return ''
  return text.includes('\n') ? `${t}\n` : t
}

/** The part of a `$.session.messages()` row the restore reads. */
export type SessionRow = { readonly role: 'user' | 'assistant'; readonly text: string; readonly toolUses: readonly unknown[] }

/**
 * Working notes and replies in a restored transcript, where each content block
 * is its own row: assistant text is a working note when its row, or a later
 * assistant row before the next user row, called tools, and it is not substantive.
 */
export function classifyRestored(rows: readonly SessionRow[]): { notes: string[]; replies: string[] } {
  const notes = new Set<string>()
  const replies = new Set<string>()
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]!
    if (row.role !== 'assistant') continue
    const key = noteKey(row.text)
    if (key === '') continue
    let toolsFollow = row.toolUses.length > 0
    for (let j = i + 1; !toolsFollow && j < rows.length && rows[j]!.role === 'assistant'; j++) {
      if (rows[j]!.toolUses.length > 0) toolsFollow = true
    }
    if (toolsFollow && !isSubstantive(row.text)) notes.add(key)
    else replies.add(key)
  }
  for (const key of replies) notes.delete(key)
  return { notes: [...notes], replies: [...replies] }
}
