// State contract for the fixer-lowkey mod.

/** One live merc, as the band above the prompt draws it. */
export type CrewEntry = {
  /** The job id, which is also the merc's Herdr agent name. */
  id: string
  /** The job status from data/jobs/<id>/job.conf, refined by Herdr: `dialog` when the merc sits at an approval UI. */
  state: string
}

declare module 'claude-code' {
  interface PluginState {
    'fixer-lowkey': {
      /** Whether lowkey is on (config/fixer.conf: on unless lowkey=off). */
      lowkey: boolean
      /** Animation frame counter; advances while a turn runs with lowkey on. */
      frame: number
      /** Live mercs for the band. */
      crew: Shaped<CrewEntry[]>
    }
  }
}
