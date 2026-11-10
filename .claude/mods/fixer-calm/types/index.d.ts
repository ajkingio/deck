// State contract for the fixer-calm mod.

/** One live runner, as the crew band draws it. */
export type CrewEntry = {
  /** The job id, which is also the runner's Herdr agent name. */
  id: string
  /** The job status from data/jobs/<id>/job.conf, refined by Herdr: `dialog` when the runner sits at an approval UI. */
  state: string
}

declare module 'claude-code' {
  interface PluginState {
    'fixer-calm': {
      /** Whether calm is on (config/fixer.conf calm=on). */
      calm: boolean
      /** The working-row animation the active theme asks for (`hex-stream`), or `none` for the stock spinner. */
      sprite: string
      /** Animation frame counter; advances while a turn runs with calm on. */
      frame: number
      /** The crew band's title, from the theme's `crew_label` (DAEMONS, MERCS, CREW). */
      label: string
      /** The theme's name for the toggle command (`ghost`, `lowkey`, `calm`, `focus`). */
      command: string
      /** Live runners for the crew band. */
      crew: Shaped<CrewEntry[]>
    }
  }
}
