// deck-operator: Pi extension for the deck operator (Pi as the agent the user talks to).
//
// Pi has no background shell command, so the Claude Code pattern (the operator
// runs bin/deck-wait in the background and is woken when it exits) can't work.
// This extension owns the watcher instead:
//
//   - Watcher: whenever jobs are running or blocked (checked on session start,
//     when a turn settles, and after each deck-wait exit) it runs bin/deck-wait
//     as a child process. When deck-wait prints events, they are delivered to the
//     operator as a follow-up user message, and the watcher restarts if jobs
//     remain. deck-wait's own lock (state/wait.pid) keeps it to one watcher; an
//     "already watching" exit (3) is retried later. The child is killed on
//     session shutdown.
//   - Settle backstop (agent_before_settle): the Pi equivalent of the Claude
//     Stop hook bin/deck-turnend-guard. If jobs are live and no watcher is
//     alive, it starts one. The model is never asked to.
//   - Write guard (tool_call): enforces hard rule 1 (never write to a project).
//     Blocks the write/edit tools, and bash output redirections (> >> &> tee),
//     whose target is under projects/, a registered project's path
//     (data/projects/*.conf), a job's worktree, or the deck repo itself.
//     Allowed inside the deck repo: config/, data/, state/ (private state), and
//     learned/ and .agents/skills/, the targets of an accepted /defrag proposal
//     (AGENTS.md §8). Not caught: other bash writes (cp, mv, sed -i, git
//     commit, scripts...), and redirections after a `cd` inside the same
//     command. Those stay instruction-only.
//
// Scope: active only in the operator's home, the same rule as
// bin/deck-turnend-guard: the deck checkout must not be a linked git worktree
// (.git is a file there) and must have data/jobs. Workers on the deck project
// run in worktrees and may load this file; there it does nothing.
//
// Fails open on its own errors (logged to state/pi-operator.log), except the
// write guard, which blocks a path it can positively place under a project
// even when canonicalising it fails.
//
// Only erasable TypeScript, so node can import it directly for tests
// (tests/pi-operator.test.mjs).

import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// ------------------------------------------------------------------ helpers

/** The deck checkout this file lives in (<root>/.pi/extensions/deck-operator.ts). */
export function deckRootFromFile(file: string): string {
  return resolve(dirname(file), "..", "..");
}

/** The operator's home: not a linked git worktree, and data/jobs exists. */
export function isOperatorHome(root: string): boolean {
  try {
    const git = join(root, ".git");
    if (existsSync(git) && statSync(git).isFile()) return false;
    return existsSync(join(root, "data", "jobs")) && statSync(join(root, "data", "jobs")).isDirectory();
  } catch {
    return false;
  }
}

/** Last value of <key>= in a key=value file, or "". */
export function confGet(file: string, key: string): string {
  try {
    let v = "";
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (line.startsWith(key + "=")) v = line.slice(key.length + 1);
    }
    return v;
  } catch {
    return "";
  }
}

function jobConfs(root: string): string[] {
  const dir = join(root, "data", "jobs");
  try {
    return readdirSync(dir)
      .map((d) => join(dir, d, "job.conf"))
      .filter((f) => existsSync(f));
  } catch {
    return [];
  }
}

/** Ids of jobs whose status is running or blocked. */
export function liveJobs(root: string): string[] {
  return jobConfs(root)
    .filter((f) => ["running", "blocked"].includes(confGet(f, "status")))
    .map((f) => basename(dirname(f)));
}

/** deck-wait output reduced to the lines that need the operator. */
export function actionableEvents(out: string): string[] {
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "" && l !== "no events" && !l.startsWith("none ") && !l.startsWith("already watching"));
}

export function eventMessage(events: string[]): string {
  return [
    "deck-wait events (the deck Pi extension's watcher):",
    "",
    ...events,
    "",
    "Handle them per AGENTS.md §4. The extension restarts the watcher itself; don't run bin/deck-wait.",
  ].join("\n");
}

// ------------------------------------------------------------- write guard

/** Canonical form of a path that may not exist yet: realpath of its deepest existing ancestor, plus the rest. */
export function canonical(p: string): string {
  let head = resolve(p);
  const rest: string[] = [];
  for (;;) {
    try {
      const real = realpathSync.native(head);
      return rest.length ? join(real, ...rest.reverse()) : real;
    } catch {
      const parent = dirname(head);
      if (parent === head) return resolve(p);
      rest.push(basename(head));
      head = parent;
    }
  }
}

export function within(p: string, root: string): boolean {
  return p === root || p.startsWith(root.endsWith(sep) ? root : root + sep);
}

/** Inside the deck repo, the operator may write here (relative to the deck root). */
export const OPERATOR_WRITABLE = ["config", "data", "state", "learned", join(".agents", "skills")];

/** Every path the operator must not write: the deck repo, projects/, registered projects, job worktrees. */
export function protectedRoots(root: string): string[] {
  const roots = new Set<string>([root, join(root, "projects")]);
  const pdir = join(root, "data", "projects");
  let confs: string[] = [];
  try {
    confs = readdirSync(pdir).filter((f) => f.endsWith(".conf")).map((f) => join(pdir, f));
  } catch {
    // no registry: the deck repo and projects/ are still protected
  }
  for (const f of confs) {
    const p = confGet(f, "path");
    if (p && isAbsolute(p)) roots.add(p);
  }
  for (const f of jobConfs(root)) {
    const w = confGet(f, "worktree");
    if (w && isAbsolute(w)) roots.add(w);
  }
  const out = new Set<string>();
  for (const r of roots) {
    out.add(resolve(r));
    out.add(canonical(r));
  }
  return [...out];
}

function expandHome(p: string): string {
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return join(homedir(), p.slice(2));
  return p;
}

/**
 * Why writing <target> (relative to <cwd>) breaks hard rule 1, or "" if it may be written.
 * <root> is the deck root, already canonical.
 */
export function writeRefusal(root: string, cwd: string, target: string): string {
  const raw = expandHome(target.replace(/^@/, ""));
  const lexical = resolve(cwd, raw);
  let real = lexical;
  try {
    real = canonical(lexical);
  } catch {
    // keep the lexical path; it is still checked below
  }
  const roots = protectedRoots(root);
  const owner = (p: string): string => {
    // The most specific protected root that contains p.
    let best = "";
    for (const r of roots) if (within(p, r) && r.length > best.length) best = r;
    return best;
  };
  for (const p of [lexical, real]) {
    const r = owner(p);
    if (!r) continue;
    if (r === root || r === canonical(root)) {
      const base = r;
      if (OPERATOR_WRITABLE.some((d) => within(p, join(base, d)))) continue;
      return `${p} is a tracked file of the deck repo. Hard rule 1: changes to deck's code and docs are gigs; hire a worker. (Only config/, data/, state/, and learned/ and .agents/skills/ for an accepted /defrag proposal, are yours to edit.)`;
    }
    return `${p} is inside a project (${r}). Hard rule 1: never write to a project; hire a worker for it.`;
  }
  return "";
}

/** Targets of output redirections and tee in a shell command (best effort). */
export function bashWriteTargets(command: string): string[] {
  // Mask quoted strings first, so a ">" inside one (awk '$1 > 5', jq '.n > 1')
  // isn't read as a redirection; a masked token that is a target maps back.
  const quoted: string[] = [];
  const masked = command.replace(/"(?:[^"\\]|\\.)*"|'[^']*'/g, (q) => {
    quoted.push(q.slice(1, -1));
    return `\u0000${quoted.length - 1}\u0000`;
  });
  const word = (tok: string): string => tok.replace(/\u0000(\d+)\u0000/g, (_m, i) => quoted[Number(i)]);
  const out: string[] = [];
  const keep = (t: string): void => {
    if (!t || t.startsWith("&") || t.startsWith("/dev/")) return;
    out.push(t);
  };
  // > >> >| 2> &> &>> ; a >&N target (fd duplication) is skipped by keep().
  for (const m of masked.matchAll(/(?:^|[^<>])(?:[0-9]+|&)?>>?\|?\s*([^\s;&|<>()]+)/g)) keep(word(m[1]));
  for (const m of masked.matchAll(/(?:^|[|;&(\s])tee((?:\s+[^\s;&|<>()]+)+)/g)) {
    for (const tok of m[1].trim().split(/\s+/)) {
      if (tok.startsWith("-")) continue;
      keep(word(tok));
    }
  }
  return out;
}

// ---------------------------------------------------------------- extension

export default function deckOperator(pi: ExtensionAPI): void {
  let root: string;
  try {
    root = canonical(deckRootFromFile(fileURLToPath(import.meta.url)));
  } catch {
    return;
  }
  if (!isOperatorHome(root)) return; // a worker's worktree, or not a deck home

  const logFile = join(root, "state", "pi-operator.log");
  const log = (msg: string): void => {
    try {
      mkdirSync(dirname(logFile), { recursive: true });
      appendFileSync(logFile, `${new Date().toISOString()} ${msg}\n`);
    } catch {
      // logging must never break the session
    }
  };

  let child: ChildProcess | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let stopped = true;
  let failures = 0;
  let pending: string[] = []; // events Pi didn't accept yet

  const deliver = async (): Promise<void> => {
    if (pending.length === 0) return;
    const events = pending;
    pending = [];
    try {
      await pi.sendUserMessage(eventMessage(events), { deliverAs: "followUp" });
    } catch (e) {
      pending = events.concat(pending);
      log(`could not deliver events, will retry when the turn settles: ${String(e)}`);
    }
  };

  const later = (ms: number): void => {
    if (retry || stopped) return;
    retry = setTimeout(() => {
      retry = null;
      ensureWatcher("retry");
    }, ms);
    retry.unref?.();
  };

  function ensureWatcher(why: string): void {
    try {
      if (stopped || child) return;
      if (liveJobs(root).length === 0) return;
      const proc = spawn(join(root, "bin", "deck-wait"), [], {
        cwd: root,
        stdio: ["ignore", "pipe", "pipe"],
        env: process.env,
      });
      child = proc;
      let out = "";
      let err = "";
      proc.stdout?.on("data", (d) => (out += String(d)));
      proc.stderr?.on("data", (d) => (err += String(d)));
      proc.on("error", (e) => {
        log(`deck-wait failed to start: ${String(e)}`);
      });
      proc.on("close", (code) => {
        if (child === proc) child = null;
        if (stopped) return;
        if (code === 0) {
          failures = 0;
          const events = actionableEvents(out);
          if (events.length) {
            pending.push(...events);
            void deliver();
          }
          ensureWatcher("restart");
        } else if (code === 3) {
          // Another watcher holds state/wait.pid (another session, or a leftover); check again later.
          later(30_000);
        } else {
          failures++;
          log(`deck-wait exited ${code}: ${err.trim()}`);
          later(Math.min(300_000, 5_000 * 2 ** Math.min(failures, 6)));
        }
      });
      log(`watcher started (${why})`);
    } catch (e) {
      child = null;
      log(`watcher error: ${String(e)}`);
    }
  }

  const stop = (): void => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    if (child && child.exitCode === null) {
      try {
        child.kill("SIGTERM");
      } catch {
        // already gone
      }
    }
    child = null;
  };

  pi.on("session_start", async () => {
    stopped = false;
    ensureWatcher("session start");
  });

  pi.on("agent_before_settle", async () => {
    ensureWatcher("settle backstop");
    return undefined;
  });

  pi.on("agent_settled", async () => {
    await deliver();
    ensureWatcher("settled");
  });

  pi.on("session_shutdown", async () => {
    stop();
  });
  process.once("exit", stop);

  pi.on("tool_call", async (event, ctx) => {
    let targets: string[] = [];
    try {
      const input = event.input as Record<string, unknown>;
      if (event.toolName === "write" || event.toolName === "edit") {
        const p = input.path ?? input.file_path;
        if (typeof p === "string") targets = [p];
      } else if (event.toolName === "bash" && typeof input.command === "string") {
        targets = bashWriteTargets(input.command);
      }
    } catch (e) {
      log(`write guard could not read a ${event.toolName} call: ${String(e)}`);
      return undefined;
    }
    for (const t of targets) {
      let why = "";
      try {
        why = writeRefusal(root, ctx.cwd, t);
      } catch (e) {
        log(`write guard error on ${t}: ${String(e)}`);
        continue;
      }
      if (why) {
        log(`blocked ${event.toolName}: ${t}`);
        return { block: true, reason: `deck: ${why}` };
      }
    }
    return undefined;
  });
}
