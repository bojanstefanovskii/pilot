// biome-ignore-all lint/complexity/useLiteralKeys: Exercise private lifecycle seams.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { test } from "node:test";
import { fixture, git } from "./testing/session-workspace.ts";

async function worktreeFixture(t: Parameters<typeof fixture>[0]) {
	const f = await fixture(t, {}, { gitOnly: true });
	await f.projects.update(f.project.id, { workspace: "worktree" });
	const listed = () =>
		git(f.source, "worktree", "list", "--porcelain")
			.split("\n")
			.filter((line) => line.startsWith("worktree "))
			.map((line) => line.slice("worktree ".length));
	return { ...f, listed };
}

test("a worktree project gives each chat a uniquely named Git worktree of the source", async (t) => {
	const f = await worktreeFixture(t);
	await f.projects.update(f.project.id, { scripts: { setup: [{ command: 'basename "$PWD" > name.txt' }] } });
	const chat = await f.spawn();
	assert.equal(chat.workspace, "worktree");
	assert.match(basename(chat.cwd), /^pilot-[0-9a-f]{8}$/);
	assert.equal(basename(chat.cwd), `pilot-${chat.id.replace(/-/g, "").slice(0, 8)}`);
	// Scripts that rely on `git worktree list` (port slots, per-worktree databases) see it next to the checkout.
	assert.ok(
		f.listed().some((path) => path.endsWith(basename(chat.cwd))),
		f.listed().join("\n"),
	);
	assert.equal((await readFile(join(chat.cwd, "name.txt"), "utf8")).trim(), basename(chat.cwd));
	assert.equal(await readFile(join(chat.cwd, "tracked.txt"), "utf8"), "base\n");
	assert.equal(await readFile(join(f.source, "tracked.txt"), "utf8"), "source dirty, never touch\n");
	assert.equal(f.specs.at(-1)?.pilot?.workspace?.worktree, true);
	const stored = await f.stored(chat.id);
	assert.equal(stored.workspace?.worktree, true);
	assert.equal(stored.workspace?.jj, false);
});

test("reclaiming an archived worktree runs teardown, removes it, and restoring brings its branch back", async (t) => {
	const f = await worktreeFixture(t);
	const log = join(f.root, "teardown.log");
	await f.projects.update(f.project.id, {
		scripts: {
			setup: [{ command: "true" }],
			teardown: [{ name: "drop db", command: `basename "$PWD" >> '${log}'` }],
		},
	});
	const chat = await f.spawn();
	git(chat.cwd, "checkout", "--quiet", "-b", "feat/agent-work");
	await writeFile(join(chat.cwd, "tracked.txt"), "agent change\n");
	git(chat.cwd, "commit", "--quiet", "-am", "agent change");

	await f.sessions.archive(chat.id);
	await f.sessions.reclaimWorkspace(chat.id);
	assert.equal(existsSync(chat.cwd), false);
	assert.ok(!f.listed().some((path) => path.endsWith(basename(chat.cwd))));
	assert.equal((await readFile(log, "utf8")).trim(), basename(chat.cwd));
	const reclaimed = await f.stored(chat.id);
	assert.deepEqual(reclaimed.workspaceRecovery, { worktree: true, ref: "feat/agent-work", phase: "reclaimed" });
	// The branch lives in the shared repository, so nothing was lost.
	assert.match(git(f.source, "branch", "--list", "feat/agent-work"), /feat\/agent-work/);

	await f.sessions.restore(chat.id);
	assert.equal(git(chat.cwd, "branch", "--show-current"), "feat/agent-work");
	assert.equal(await readFile(join(chat.cwd, "tracked.txt"), "utf8"), "agent change\n");
	const restored = await f.stored(chat.id);
	assert.equal(restored.workspaceRecovery, undefined);
	assert.equal(restored.setupPending, true, "teardown freed the environment, so setup runs again");
});

test("a worktree with uncommitted changes is kept, and a failing teardown keeps it too", async (t) => {
	const f = await worktreeFixture(t);
	const chat = await f.spawn();
	await writeFile(join(chat.cwd, "draft.txt"), "unsaved\n");
	await f.sessions.archive(chat.id);
	await assert.rejects(f.sessions.reclaimWorkspace(chat.id), /uncommitted changes, so it is kept/);
	assert.ok(existsSync(join(chat.cwd, "draft.txt")));
	assert.equal((await f.stored(chat.id)).workspaceRecovery, undefined);

	await f.sessions.restore(chat.id);
	git(chat.cwd, "checkout", "--quiet", "-b", "feat/kept");
	git(chat.cwd, "add", "draft.txt");
	git(chat.cwd, "commit", "--quiet", "-m", "draft");
	await f.projects.update(f.project.id, { scripts: { teardown: [{ name: "drop db", command: "exit 4" }] } });
	await f.sessions.archive(chat.id);
	await assert.rejects(f.sessions.reclaimWorkspace(chat.id), /Teardown failed: drop db \(exit 4\)/);
	assert.ok(existsSync(chat.cwd), "the worktree stays until teardown succeeds");
	await f.sessions.restore(chat.id);
	assert.equal(existsSync(chat.cwd), true);
	assert.equal((await f.stored(chat.id)).workspaceRecovery, undefined);
});
