// biome-ignore-all lint/complexity/useLiteralKeys: Exercise private lifecycle seams.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fixture } from "./testing/session-workspace.ts";

async function started(f: Awaited<ReturnType<typeof fixture>>, id: string) {
	await f.sessions["starting"].get(id);
	await Promise.all([...f.sessions["saving"].values()]);
}

test("setup scripts run once in a new Build workspace before the first turn", async (t) => {
	const f = await fixture(t);
	await f.projects.update(f.project.id, {
		scripts: { setup: [{ name: "mark", command: 'echo "$PILOT_SESSION_ID" >> setup.log' }] },
	});
	const created = await f.sessions.spawn({ projectId: f.project.id, message: "with setup" });
	await started(f, created.id);
	const chat = f.sessions.get(created.id)!;
	assert.equal(chat.state, "working", f.sessions["metas"].get(created.id)?.failure);
	assert.equal((await readFile(join(chat.cwd, "setup.log"), "utf8")).trim(), created.id);
	assert.equal(chat.setup?.state, "ok");
	assert.equal(chat.setup?.results[0]?.name, "mark");
	const stored = await f.stored(created.id);
	assert.equal(stored.setupPending, undefined);
	assert.ok(f.workers.length >= 1, "the agent starts after setup");
	await f.sessions.stop(created.id);
});

test("a failing setup fails the chat with a retryable startup failure, and Retry runs it again", async (t) => {
	const f = await fixture(t);
	await f.projects.update(f.project.id, {
		scripts: { setup: [{ name: "needs flag", command: "test -f ready.flag || { echo missing flag; exit 2; }" }] },
	});
	const workersBefore = f.workers.length;
	const created = await f.sessions.spawn({ projectId: f.project.id, message: "setup fails" });
	await started(f, created.id);
	let chat = f.sessions.get(created.id)!;
	assert.equal(chat.state, "failed");
	assert.equal(chat.canRetryStartup, true);
	assert.match(chat.error ?? "", /Setup failed: needs flag \(exit 2\)/);
	assert.equal(chat.setup?.state, "failed");
	assert.match(chat.setup?.results[0]?.output ?? "", /missing flag/);
	assert.equal(f.workers.length, workersBefore, "no agent starts after a failed setup");

	await writeFile(join(chat.cwd, "ready.flag"), "");
	await f.sessions.retryStartup(created.id);
	await started(f, created.id);
	chat = f.sessions.get(created.id)!;
	assert.equal(chat.setup?.state, "ok");
	assert.notEqual(chat.state, "failed", f.sessions["metas"].get(created.id)?.failure);
	await f.sessions.stop(created.id);
});

test("projects without setup scripts start exactly as before", async (t) => {
	const f = await fixture(t);
	const chat = await f.spawn();
	assert.equal(chat.setup, undefined);
	assert.equal((await f.stored(chat.id)).setupPending, undefined);
});

test("checks run once per workspace state and send at most three failures back to the agent", async (t) => {
	const f = await fixture(t);
	await f.projects.update(f.project.id, {
		scripts: { checks: [{ name: "lint", command: "test ! -f bad.txt || { echo lint error; exit 1; }" }] },
	});
	const chat = await f.spawn();
	const meta = () => f.sessions["metas"].get(chat.id)!;
	// A turn ending also starts checks on its own; wait for any run in flight, then run once more.
	const settle = async () => {
		while (f.sessions["checksRunning"].has(chat.id)) await new Promise((resolve) => setTimeout(resolve, 10));
	};
	const check = async () => {
		await settle();
		await f.sessions["runWorkspaceChecks"](meta());
		await settle();
	};
	const followUps = () =>
		(meta().pending ?? []).filter((command) => command.requestId?.startsWith("checks-follow-up:"));

	await check();
	assert.equal(meta().checks?.state, "ok");
	assert.equal(followUps().length, 0);

	for (let round = 1; round <= 4; round++) {
		await writeFile(join(chat.cwd, "bad.txt"), `round ${round}\n`);
		await writeFile(join(chat.cwd, `change-${round}.txt`), "");
		await check();
		assert.equal(meta().checks?.state, "failed");
	}
	assert.equal(meta().checksFollowUps, 3);
	const sent = (meta().pending ?? []).filter((command) => command.requestId?.startsWith("checks-follow-up:"));
	assert.ok(sent.length <= 3);

	const before = meta().checks?.finishedAt;
	await check();
	assert.equal(meta().checks?.finishedAt, before, "an unchanged workspace is not checked again");
	assert.equal(f.sessions.get(chat.id)?.checks?.results[0]?.name, "lint");
	assert.equal((f.sessions.get(chat.id)?.checks as { fingerprint?: string } | undefined)?.fingerprint, undefined);
});

test("a Quick fix chat runs the light quick setup with PILOT_KIND, a Feature chat the full setup", async (t) => {
	const f = await fixture(t);
	await f.projects.update(f.project.id, {
		scripts: {
			setup: [{ command: 'echo "full $PILOT_KIND" > setup.log' }],
			quickSetup: [{ command: 'echo "quick $PILOT_KIND" > setup.log' }],
		},
	});
	const quick = await f.sessions.spawn({ projectId: f.project.id, message: "typo", kind: "quick" });
	await started(f, quick.id);
	assert.equal((await readFile(join(f.sessions.get(quick.id)!.cwd, "setup.log"), "utf8")).trim(), "quick quick");
	assert.equal(f.sessions.get(quick.id)?.kind, "quick");
	const feature = await f.sessions.spawn({ projectId: f.project.id, message: "feature" });
	await started(f, feature.id);
	assert.equal((await readFile(join(f.sessions.get(feature.id)!.cwd, "setup.log"), "utf8")).trim(), "full feature");
	assert.equal(f.sessions.get(feature.id)?.kind, undefined);
	await assert.rejects(
		f.sessions.spawn({ projectId: f.project.id, message: "x", kind: "huge" as never }),
		/kind must be/,
	);
	await f.sessions.stop(quick.id);
	await f.sessions.stop(feature.id);
});
