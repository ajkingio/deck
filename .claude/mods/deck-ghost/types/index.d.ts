// State contract for the deck-ghost mod.

/** One live daemon, as the band above the prompt draws it. */
export type CrewEntry = {
  /** The job id, which is also the daemon's Herdr agent name. */
  id: string
  /** The job status from data/jobs/<id>/job.conf, refined by Herdr: `dialog` when the daemon sits at an approval UI. */
  state: string
}

declare module 'claude-code' {
  interface PluginState {
    'deck-ghost': {
      /** Whether ghost is on (config/deck.conf: on unless ghost=off). */
      ghost: boolean
      /** Animation frame counter; advances with ghost on while a turn runs or a daemon is working. */
      frame: number
      /** Whether any daemon is working: job status starting/running, and Herdr does not see its pane blocked, idle or done. */
      working: boolean
      /** Live daemons for the band. */
      crew: Shaped<CrewEntry[]>
    }
  }
}
