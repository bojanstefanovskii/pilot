// biome-ignore-all lint/complexity/useLiteralKeys: Exercise private lifecycle seams.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import type { SessionMissionBridge } from "./sessions.ts";
import { fixture } from "./testing/session-workspace.ts";

async function squad(t: Parameters<typeof fixture>[0]) {
	const f = await fixture(t);
	f.sessions.setMissionBridge({
		membership: () => ({ missionId: "m1", active: true, coordinator: false }),
		context: () => undefined,
		spawnProject: () => f.project.id,
		joinSpawn() {},
		call: async () => ({}),
	} as unknown as SessionMissionBridge);
	await f.projects.update(f.project.id, {
		scripts: {
			setup: [{ command: 'echo "full" > env.txt' }],
			agentSetup: [{ command: 'echo "shared $PILOT_MISSION_ID $PILOT_MISSION_ENV" > env.txt' }],
		},
	});
	const start = async (message: string) => {
		const created = await f.sessions.spawn({ projectId: f.project.id, message });
		await f.sessions["starting"].get(created.id);
		await Promise.all([...f.sessions["saving"].values()]);
		await f.sessions.stop(created.id);
		return f.sessions.get(created.id)!;
	};
	const env = async (cwd: string) => (await readFile(join(cwd, "env.txt"), "utf8")).trim();
	return { ...f, start, env };
}

test("the first squad agent sets up the mission environment and the next ones share it", async (t) => {
	const f = await squad(t);
	const first = await f.start("agent one");
	assert.equal(await f.env(first.cwd), "full");
	assert.equal(first.missionEnvOwner, true);
	const second = await f.start("agent two");
	assert.equal(await f.env(second.cwd), `shared m1 ${first.cwd}`);
	assert.equal(second.missionEnv, first.cwd);
	assert.equal(f.specs.at(-1)?.pilot?.workspace?.missionEnv, first.cwd);
	await f.sessions.archive(first.id);
	await assert.rejects(f.sessions.reclaimWorkspace(first.id), /Other squad agents still use/);
});

test("Isolate gives a squad agent its own environment with the full setup", async (t) => {
	const f = await squad(t);
	const first = await f.start("agent one");
	const second = await f.start("agent two");
	const isolated = await f.sessions.isolateWorkspace(second.id);
	assert.equal(await f.env(second.cwd), "full");
	assert.equal(isolated.missionEnv, undefined);
	assert.equal(isolated.missionEnvOwner, undefined, "the mission keeps its first environment");
	assert.equal((await f.stored(second.id)).isolated, true);
	await assert.rejects(f.sessions.isolateWorkspace(first.id), /does not share/);
});
