// Tests for .pi/extensions/deck-operator.ts, run by tests/pi.test.sh:
//   node tests/pi-operator.test.mjs <deck-home> <scratch-dir>
// <deck-home> is a sandbox deck home with the extension copied into
// .pi/extensions/. The extension is driven through a fake Pi API; bin/deck-wait
// is replaced by small stubs. Exits non-zero on the first failure.
import assert from "node:assert/strict";
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [deck, scratch] = process.argv.slice(2);
const ext = join(deck, ".pi", "extensions", "deck-operator.ts");
const m = await import(pathToFileURL(ext).href);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(cond, what, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (cond()) return;
    await sleep(50);
  }
  assert.fail(`timed out waiting for: ${what}`);
}

function fakePi() {
  const handlers = {};
  const sent = [];
  return {
    handlers,
    sent,
    on(name, fn) {
      handlers[name] = fn;
    },
    async sendUserMessage(text, opts) {
      sent.push({ text, opts });
    },
    async fire(name, event = {}, ctx = { cwd: deck }) {
      return handlers[name]?.(event, ctx);
    },
  };
}

function job(id, status, extra = "") {
  mkdir(join(deck, "data", "jobs", id));
  writeFileSync(join(deck, "data", "jobs", id, "job.conf"), `id=${id}\nstatus=${status}\n${extra}`);
}
function mkdir(p) {
  mkdirSync(p, { recursive: true });
}
function stubWait(body) {
  const f = join(deck, "bin", "deck-wait");
  writeFileSync(f, `#!/bin/bash\nD=${JSON.stringify(deck)}\necho x >>"$D/state/wait-calls"\n${body}\n`);
  chmodSync(f, 0o755);
}
const waitCalls = () => {
  try {
    return readFileSync(join(deck, "state", "wait-calls"), "utf8").split("\n").filter(Boolean).length;
  } catch {
    return 0;
  }
};
const resetCalls = () => writeFileSync(join(deck, "state", "wait-calls"), "");

let failed = 0;
async function test(name, fn) {
  try {
    await fn();
    console.log(`ok ${name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${name}\n${e?.stack ?? e}`);
  }
}

mkdir(join(deck, "state"));
const project = join(scratch, "src", "app");
mkdir(project);
writeFileSync(join(deck, "data", "projects", "app.conf"), `name=app\npath=${project}\n`);
mkdir(join(deck, "projects", "cloned"));
const worktree = join(scratch, "worktrees", "app-wt");
mkdir(worktree);

// ---------------------------------------------------------------- pure logic

await test("scope: operator home only", () => {
  assert.equal(m.isOperatorHome(deck), true);
  const wt = join(scratch, "linked");
  mkdir(join(wt, "data", "jobs"));
  writeFileSync(join(wt, ".git"), "gitdir: /somewhere\n");
  assert.equal(m.isOperatorHome(wt), false, "a linked worktree");
  const bare = join(scratch, "nojobs");
  mkdir(bare);
  assert.equal(m.isOperatorHome(bare), false, "no data/jobs");
  assert.equal(m.deckRootFromFile(ext), deck);
});

await test("live jobs and events", () => {
  job("a-run", "running");
  job("b-blk", "blocked");
  job("c-rev", "review");
  assert.deepEqual(m.liveJobs(deck).sort(), ["a-run", "b-blk"]);
  assert.deepEqual(m.actionableEvents("a done ok\nnone no running jobs to watch\nno events\n\nb blocked q?\n"), [
    "a done ok",
    "b blocked q?",
  ]);
  job("a-run", "review");
  job("b-blk", "review");
});

await test("write guard: what the operator may and may not write", () => {
  job("app-wt", "review", `worktree=${worktree}\n`);
  const no = (p, why) => assert.notEqual(m.writeRefusal(deck, deck, p), "", `${p} should be blocked`);
  const yes = (p) => assert.equal(m.writeRefusal(deck, deck, p), "", `${p} should be allowed`);
  yes("data/jobs/x/brief.md");
  yes("config/deck.conf");
  yes("state/last-defrag");
  yes("learned/brief-addendum.md");
  yes(".agents/skills/new-skill/SKILL.md");
  yes(join(scratch, "elsewhere.txt"));
  yes("/tmp/deck-pi-test-scratch.txt");
  no("bin/deck-spawn");
  no("AGENTS.md");
  no(".pi/extensions/deck-operator.ts");
  no("templates/gig-brief.md");
  no("data/../bin/deck-wait");
  no("projects/cloned/README.md");
  no(join(project, "src", "main.ts"));
  no(join(worktree, "README.md"));
  // Through a symlink inside data/ into a project: blocked by its real path.
  symlinkSync(project, join(deck, "data", "link-to-app"));
  no("data/link-to-app/README.md");
  // Relative to another cwd.
  assert.notEqual(m.writeRefusal(deck, project, "x.txt"), "");
  assert.match(m.writeRefusal(deck, deck, "bin/x"), /gigs/);
  assert.match(m.writeRefusal(deck, deck, join(project, "x")), /inside a project/);
});

await test("bash write targets", () => {
  assert.deepEqual(m.bashWriteTargets("echo hi > a; cat x>>b 2>&1"), ["a", "b"]);
  assert.deepEqual(m.bashWriteTargets(`awk '$1 > 5' f; jq ".n > 1" g >/dev/null; echo >&2 x`), []);
  assert.deepEqual(m.bashWriteTargets(`foo | tee -a c "d e"; cmd &> h; printf x>"q r"`).sort(), ["c", "d e", "h", "q r"].sort());
  assert.deepEqual(m.bashWriteTargets("bin/deck-job list"), []);
});

// ---------------------------------------------------------------- the extension

await test("inert outside the operator's home", async () => {
  const wt = join(scratch, "worker-wt");
  mkdir(join(wt, ".pi", "extensions"));
  mkdir(join(wt, "data", "jobs"));
  writeFileSync(join(wt, ".git"), "gitdir: /somewhere\n");
  cpSync(ext, join(wt, ".pi", "extensions", "deck-operator.ts"));
  const w = await import(pathToFileURL(join(wt, ".pi", "extensions", "deck-operator.ts")).href);
  const pi = fakePi();
  w.default(pi);
  assert.deepEqual(Object.keys(pi.handlers), []);
});

await test("tool_call blocks writes into projects and deck's tracked files", async () => {
  const pi = fakePi();
  m.default(pi);
  const call = (toolName, input) => pi.fire("tool_call", { toolName, input });
  assert.equal((await call("write", { path: "bin/deck-new" }))?.block, true);
  assert.equal((await call("edit", { path: join(project, "a.ts") }))?.block, true);
  assert.equal(await call("write", { path: "data/jobs/x/brief.md" }), undefined);
  assert.equal((await call("bash", { command: "echo x > projects/cloned/a" }))?.block, true);
  assert.equal(await call("bash", { command: "bin/deck-job list > /dev/null" }), undefined);
  assert.equal(await call("read", { path: "bin/deck-spawn" }), undefined);
  await pi.fire("session_shutdown");
});

await test("watcher: delivers events as a follow-up and stops when no jobs remain", async () => {
  resetCalls();
  job("w-job", "running");
  stubWait(`echo "w-job done branch ready"; sed -i '' 's/^status=.*/status=review/' "$D/data/jobs/w-job/job.conf"; exit 0`);
  const pi = fakePi();
  m.default(pi);
  await pi.fire("session_start", { reason: "startup" });
  await until(() => pi.sent.length === 1, "one delivered message");
  assert.match(pi.sent[0].text, /w-job done branch ready/);
  assert.equal(pi.sent[0].opts.deliverAs, "followUp");
  await sleep(300);
  assert.equal(waitCalls(), 1, "not restarted once no jobs are live");
  await pi.fire("session_shutdown");
});

await test("watcher: restarts while jobs remain, and ignores 'none' output", async () => {
  resetCalls();
  job("w-job", "running");
  stubWait(`n=$(wc -l <"$D/state/wait-calls"); if [ "$n" -ge 3 ]; then sed -i '' 's/^status=.*/status=review/' "$D/data/jobs/w-job/job.conf"; echo "none no running jobs to watch"; else echo "w-job idle worker stopped"; fi; exit 0`);
  const pi = fakePi();
  m.default(pi);
  await pi.fire("session_start", { reason: "startup" });
  await until(() => waitCalls() === 3, "three watcher runs");
  await sleep(300);
  assert.equal(pi.sent.length, 2);
  assert.ok(pi.sent.every((s) => !/none no running/.test(s.text)));
  await pi.fire("session_shutdown");
});

await test("watcher: 'already watching' (exit 3) is not delivered or retried at once", async () => {
  resetCalls();
  job("w-job", "running");
  stubWait(`echo "already watching (pid 1)"; exit 3`);
  const pi = fakePi();
  m.default(pi);
  await pi.fire("session_start", { reason: "startup" });
  await until(() => waitCalls() === 1, "one watcher run");
  await sleep(500);
  assert.equal(waitCalls(), 1);
  assert.equal(pi.sent.length, 0);
  await pi.fire("session_shutdown");
  job("w-job", "review");
});

await test("settle backstop starts a watcher; shutdown kills it", async () => {
  resetCalls();
  job("w-job", "review");
  stubWait(`echo $$ >"$D/state/stub-wait.pid"; exec sleep 30`);
  const pi = fakePi();
  m.default(pi);
  await pi.fire("session_start", { reason: "startup" });
  await sleep(200);
  assert.equal(waitCalls(), 0, "no watcher without live jobs");
  job("w-job", "running");
  const r = await pi.fire("agent_before_settle", { entries: [] });
  assert.equal(r, undefined, "never asks the model to continue");
  await until(() => existsSync(join(deck, "state", "stub-wait.pid")), "watcher started");
  const pid = Number(readFileSync(join(deck, "state", "stub-wait.pid"), "utf8"));
  await pi.fire("agent_before_settle", { entries: [] });
  await sleep(200);
  assert.equal(waitCalls(), 1, "only one watcher");
  await pi.fire("session_shutdown");
  await until(() => {
    try {
      process.kill(pid, 0);
      return false;
    } catch {
      return true;
    }
  }, "watcher killed on shutdown");
  job("w-job", "review");
});

if (failed) process.exit(1);
