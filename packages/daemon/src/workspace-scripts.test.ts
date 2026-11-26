import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
	describeScriptFailure,
	runWorkspaceScripts,
	SCRIPT_OUTPUT_CAP,
	validateWorkspaceScripts,
} from "./workspace-scripts.ts";

const options = (cwd: string, signal?: AbortSignal) => ({
	cwd,
	env: { PILOT_SESSION_ID: "s1" },
	shell: "/bin/sh",
	signal,
});

async function withDir(run: (dir: string) => Promise<void>) {
	const dir = await mkdtemp(join(tmpdir(), "pilot-scripts-"));
	try {
		await run(dir);
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
}

test("validation trims steps, drops empty parts and rejects unknown fields", () => {
	assert.deepEqual(
		validateWorkspaceScripts({ setup: [{ command: "  pnpm i ", name: " deps " }], run: " ", checks: [] }),
		{ setup: [{ command: "pnpm i", name: "deps" }] },
	);
	assert.equal(validateWorkspaceScripts({ setup: [] }), undefined);
	assert.deepEqual(validateWorkspaceScripts({ teardown: [{ command: "drop" }] }), { teardown: [{ command: "drop" }] });
	assert.equal(validateWorkspaceScripts(null), undefined);
	assert.throws(() => validateWorkspaceScripts({ cleanup: [] }), /Unknown scripts field/);
	assert.throws(() => validateWorkspaceScripts({ setup: [{ command: "" }] }), /command/);
	assert.throws(() => validateWorkspaceScripts({ setup: [{ command: "x", timeoutMs: 10 }] }), /timeoutMs/);
});

test("steps run in order in the workspace with the PILOT_ variables", async () => {
	await withDir(async (dir) => {
		const { ok, results } = await runWorkspaceScripts(
			[{ command: 'echo "$PILOT_SESSION_ID" > id.txt' }, { command: "cat id.txt; pwd", name: "read" }],
			options(dir),
		);
		assert.equal(ok, true);
		assert.equal(results.length, 2);
		assert.equal(results[1]!.name, "read");
		assert.match(results[1]!.output, /s1/);
		assert.match(results[1]!.output, new RegExp(dir.split("/").pop()!));
	});
});

test("the first failing step stops the run and names itself", async () => {
	await withDir(async (dir) => {
		const { ok, results } = await runWorkspaceScripts(
			[{ command: "echo broken >&2; exit 3", name: "install deps" }, { command: "touch never" }],
			options(dir),
		);
		assert.equal(ok, false);
		assert.equal(results.length, 1);
		assert.equal(results[0]!.exitCode, 3);
		assert.match(results[0]!.output, /broken/);
		assert.equal(describeScriptFailure("Setup", results[0]!), "Setup failed: install deps (exit 3)");
	});
});

test("a step past its timeout is killed and reported as timed out", async () => {
	await withDir(async (dir) => {
		const { ok, results } = await runWorkspaceScripts([{ command: "sleep 5", timeoutMs: 1000 }], options(dir));
		assert.equal(ok, false);
		assert.equal(results[0]!.timedOut, true);
		assert.equal(results[0]!.exitCode, 124);
		assert.match(describeScriptFailure("Setup", results[0]!), /timed out/);
	});
});

test("only the tail of a long output is kept", async () => {
	await withDir(async (dir) => {
		const { results } = await runWorkspaceScripts(
			[{ command: "i=0; while [ $i -lt 4000 ]; do echo line-$i-xxxxxxxxxx; i=$((i+1)); done" }],
			options(dir),
		);
		assert.ok(results[0]!.output.length <= SCRIPT_OUTPUT_CAP);
		assert.match(results[0]!.output, /line-3999/);
	});
});

test("aborting stops the running step and rejects", async () => {
	await withDir(async (dir) => {
		const controller = new AbortController();
		const run = runWorkspaceScripts([{ command: "sleep 5" }], options(dir, controller.signal));
		setTimeout(() => controller.abort(new Error("stopped")), 100);
		await assert.rejects(run, /stopped/);
	});
});
