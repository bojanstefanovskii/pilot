import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { TodayStore } from "./today.ts";

test("routines rewrite sections, the user's done marks survive, and lessons carry to the next day", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "pilot-today-"));
	t.after(() => rm(home, { recursive: true, force: true }));
	let now = new Date(2026, 10, 24, 8, 0);
	const store = new TodayStore(home, () => now);
	assert.deepEqual((await store.read()).priorities, []);
	await store.write({
		summary: "Ship the renewal fix",
		priorities: [{ id: "fix", title: "Fix renewal", why: "Client waiting", url: "https://linear.app/x" }],
		quickWins: [{ title: "Bump deps" }],
		lessons: ["Prefers reviews before noon"],
	});
	await store.patchItem("fix", { done: true });
	const refreshed = await store.write({
		priorities: [{ id: "fix", title: "Fix renewal (CI red)" }, { title: "Reply to Sarah" }],
	});
	assert.equal(refreshed.priorities[0]!.done, true);
	assert.equal(refreshed.priorities[1]!.id, "reply-to-sarah");
	assert.equal(refreshed.quickWins[0]!.id, "bump-deps", "sections not given are kept");
	assert.equal(refreshed.summary, "Ship the renewal fix");
	await assert.rejects(store.write({ priorities: [{ title: "x", url: "javascript:alert(1)" }] }), /https/);
	await assert.rejects(store.patchItem("nope", { done: true }), /Unknown Today item/);

	now = new Date(2026, 10, 25, 8, 0);
	const tomorrow = await store.read();
	assert.equal(tomorrow.date, "2026-11-25");
	assert.deepEqual(tomorrow.lessons, ["Prefers reviews before noon"]);
	assert.equal(tomorrow.updatedAt, 0);
});
